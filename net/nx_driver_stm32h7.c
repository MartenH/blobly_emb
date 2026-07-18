/* net/nx_driver_stm32h7.c — NetX Duo network driver for the STM32H735 ETH MAC.
 *
 * The thin glue between NetX Duo and boards/h735dk/eth.c: it implements the
 * NX_IP_DRIVER command dispatch (the same contract as the vendored RAM driver,
 * third_party/netxduo/common/src/nx_ram_network_driver.c) and translates it into
 * eth_init/eth_send/eth_recv calls. Register-level details live entirely in eth.c;
 * this file knows nothing about the H735's registers.
 *
 * TX: the driver builds the Ethernet header + linearised payload in its own
 * buffer and hands it to eth_send (see nx_driver_ethernet_send for why not the
 * RAM driver's in-packet header trick). RX: the ETH ISR signals deferred
 * processing; NX_LINK_DEFERRED_PROCESSING drains eth_recv into NX_PACKETs routed
 * by EtherType, with the IP header 4-byte aligned (NetX checksum requirement).
 *
 * BENCH-VERIFIED on the H735-DK 2026-07-18. Scope = P1 (link + IPv4 + ICMP). */
#include "nx_api.h"
#include "eth.h"

/* Local EtherType/frame constants — the RAM driver keeps its own copies too
 * (they are not exported from nx_api.h). */
#define NX_ETHERNET_IP   0x0800u
#define NX_ETHERNET_ARP  0x0806u
#define NX_ETHERNET_IPV6 0x86DDu
#define NX_ETHERNET_SIZE 14u
#define NX_LINK_MTU      1514u

/* Station MAC — locally-administered (bit1 of the first octet set, bit0 clear).
 * The user can pin a real address later; NetX is told this in INITIALIZE. */
static UCHAR nx_driver_mac[6] = {0x02u, 0x00u, 0x00u, 0x00u, 0x00u, 0x01u};

static NX_IP *nx_driver_ip;
static NX_INTERFACE *nx_driver_interface;
static NX_PACKET_POOL *nx_driver_pool;
static UINT nx_driver_if_index;
static UINT nx_driver_initialized;

/* Scratch linearisation buffer for TX (single-threaded IP thread owns it). */
static UCHAR nx_driver_txlin[ETH_BUF_SIZE];

/* --- ISR hook: called from eth_isr on RX-complete; ask NetX to re-enter with
 * NX_LINK_DEFERRED_PROCESSING on its own IP thread (never touch packets here). */
static void nx_driver_rx_signal(void) {
	if (nx_driver_ip != NX_NULL) {
		_nx_ip_driver_deferred_processing(nx_driver_ip);
	}
}

/* --- drain every frame the DMA has delivered, wrap each in an NX_PACKET, and
 * route by EtherType. Mirrors _nx_ram_network_driver_receive. */
static void nx_driver_receive(void) {
	for (;;) {
		NX_PACKET *packet;
		if (nx_packet_allocate(nx_driver_pool, &packet, NX_RECEIVE_PACKET, NX_NO_WAIT) != NX_SUCCESS) {
			/* Pool exhausted: still DRAIN the ring — receive into the TX scratch
			 * (all driver entry is on the IP thread, so it's idle here) and drop.
			 * Bailing out instead would leave CPU-owned descriptors unrecycled,
			 * and with ring(16) > pool(12) a burst could stall RX for good. */
			while (eth_recv(nx_driver_txlin, sizeof(nx_driver_txlin)) != 0u) {
			}
			return;
		}
		/* Align the IP header to a 4-byte boundary. NetX's IP/ICMP checksum routine
		 * reads 32-bit words and mis-sums a header that isn't 4-byte aligned. The IP
		 * header sits at frame_start + 14 (Ethernet), so offset the frame so that
		 * lands on a 4-byte boundary — the standard Ethernet-driver 2-byte pad. */
		{
			uintptr_t p = (uintptr_t)packet->nx_packet_prepend_ptr;
			uint32_t off = (4u - (uint32_t)((p + NX_ETHERNET_SIZE) & 3u)) & 3u;
			packet->nx_packet_prepend_ptr += off;
		}
		uint32_t len = eth_recv(packet->nx_packet_prepend_ptr,
		                        (uint32_t)(packet->nx_packet_data_end - packet->nx_packet_prepend_ptr));
		if (len == 0u) {
			nx_packet_release(packet);
			return; /* nothing left */
		}
		packet->nx_packet_append_ptr = packet->nx_packet_prepend_ptr + len;
		packet->nx_packet_length = len;

		UINT ether_type = ((UINT)packet->nx_packet_prepend_ptr[12] << 8)
		                | (UINT)packet->nx_packet_prepend_ptr[13];
		packet->nx_packet_address.nx_packet_interface_ptr = nx_driver_interface;

		if (ether_type == NX_ETHERNET_IP || ether_type == NX_ETHERNET_IPV6) {
			packet->nx_packet_prepend_ptr += NX_ETHERNET_SIZE;
			packet->nx_packet_length -= NX_ETHERNET_SIZE;
			_nx_ip_packet_deferred_receive(nx_driver_ip, packet);
		} else if (ether_type == NX_ETHERNET_ARP) {
			packet->nx_packet_prepend_ptr += NX_ETHERNET_SIZE;
			packet->nx_packet_length -= NX_ETHERNET_SIZE;
			_nx_arp_packet_deferred_receive(nx_driver_ip, packet);
		} else {
			/* unknown EtherType (incl. RARP — never enabled here; routing it would
			 * only link dead NetX code the image can't use). */
			nx_packet_release(packet);
		}
	}
}

/* --- build the Ethernet header + linearised payload into the driver's own TX
 * buffer and transmit. Deliberately does NOT use the RAM driver's write-header-
 * backwards-into-the-packet trick (ULONG stores at prepend_ptr - 2): an echo
 * reply reuses the received packet, and that trick writes before the payload
 * area. Building in our buffer touches nothing NetX owns. */
static void nx_driver_ethernet_send(NX_IP_DRIVER *req, UINT ether_type) {
	NX_PACKET *packet = req->nx_ip_driver_packet;
	ULONG total = packet->nx_packet_length;

	if (total + NX_ETHERNET_SIZE > sizeof(nx_driver_txlin)) {
		/* Unreachable at the configured MTU (1500), but keep the guard honest:
		 * a dropped frame is not a successful send. */
		req->nx_ip_driver_status = NX_NOT_SUCCESSFUL;
		nx_packet_transmit_release(packet);
		return;
	}

	/* 14-byte header: dest MAC (from the request's msw/lsw), src MAC, EtherType. */
	UCHAR *h = nx_driver_txlin;
	h[0] = (UCHAR)(req->nx_ip_driver_physical_address_msw >> 8);
	h[1] = (UCHAR)(req->nx_ip_driver_physical_address_msw);
	h[2] = (UCHAR)(req->nx_ip_driver_physical_address_lsw >> 24);
	h[3] = (UCHAR)(req->nx_ip_driver_physical_address_lsw >> 16);
	h[4] = (UCHAR)(req->nx_ip_driver_physical_address_lsw >> 8);
	h[5] = (UCHAR)(req->nx_ip_driver_physical_address_lsw);
	h[6] = (UCHAR)(nx_driver_interface->nx_interface_physical_address_msw >> 8);
	h[7] = (UCHAR)(nx_driver_interface->nx_interface_physical_address_msw);
	h[8] = (UCHAR)(nx_driver_interface->nx_interface_physical_address_lsw >> 24);
	h[9] = (UCHAR)(nx_driver_interface->nx_interface_physical_address_lsw >> 16);
	h[10] = (UCHAR)(nx_driver_interface->nx_interface_physical_address_lsw >> 8);
	h[11] = (UCHAR)(nx_driver_interface->nx_interface_physical_address_lsw);
	h[12] = (UCHAR)(ether_type >> 8);
	h[13] = (UCHAR)(ether_type);

	/* linearise the (possibly chained) payload after the header. */
	ULONG off = NX_ETHERNET_SIZE;
	for (NX_PACKET *p = packet; p != NX_NULL; p = p->nx_packet_next) {
		ULONG chunk = (ULONG)(p->nx_packet_append_ptr - p->nx_packet_prepend_ptr);
		if (off - NX_ETHERNET_SIZE + chunk > total) {
			chunk = total - (off - NX_ETHERNET_SIZE);
		}
		for (ULONG j = 0; j < chunk; j++) {
			nx_driver_txlin[off + j] = p->nx_packet_prepend_ptr[j];
		}
		off += chunk;
		if (off - NX_ETHERNET_SIZE >= total) {
			break;
		}
	}
	if (eth_send(nx_driver_txlin, off) != 0) {
		/* TX ring full: the frame is dropped (counted in eth_tx_drops; Ethernet
		 * is lossy and protocols retransmit) — but tell NetX the truth. */
		req->nx_ip_driver_status = NX_NOT_SUCCESSFUL;
	}
	nx_packet_transmit_release(packet);
}

/* ================================================================= entry ==== */
VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr) {
	NX_IP *ip_ptr = driver_req_ptr->nx_ip_driver_ptr;
	NX_INTERFACE *interface_ptr = driver_req_ptr->nx_ip_driver_interface;

	driver_req_ptr->nx_ip_driver_status = NX_SUCCESS;

	switch (driver_req_ptr->nx_ip_driver_command) {

	case NX_LINK_INTERFACE_ATTACH:
		nx_driver_interface = interface_ptr;
		nx_driver_if_index = interface_ptr->nx_interface_index;
		break;

	case NX_LINK_INITIALIZE: {
		nx_driver_ip = ip_ptr;
		nx_driver_interface = interface_ptr;
		nx_driver_pool = ip_ptr->nx_ip_default_packet_pool;
		/* Per-chip MAC from the STM32 unique ID — two boards on one image must not
		 * share an address. SET_PHYSICAL_ADDRESS can still override at runtime. */
		eth_unique_mac(nx_driver_mac);
		eth_set_rx_callback(nx_driver_rx_signal);
		if (eth_init(nx_driver_mac) != 0) {
			driver_req_ptr->nx_ip_driver_status = NX_NOT_SUCCESSFUL;
			break;
		}
		nx_driver_initialized = 1;
		nx_ip_interface_mtu_set(ip_ptr, nx_driver_if_index, NX_LINK_MTU - NX_ETHERNET_SIZE);
		ULONG msw = ((ULONG)nx_driver_mac[0] << 8) | (ULONG)nx_driver_mac[1];
		ULONG lsw = ((ULONG)nx_driver_mac[2] << 24) | ((ULONG)nx_driver_mac[3] << 16)
		          | ((ULONG)nx_driver_mac[4] << 8) | (ULONG)nx_driver_mac[5];
		nx_ip_interface_physical_address_set(ip_ptr, nx_driver_if_index, msw, lsw, NX_FALSE);
		nx_ip_interface_address_mapping_configure(ip_ptr, nx_driver_if_index, NX_TRUE);
		break;
	}

	case NX_LINK_ENABLE:
		/* NetX issues ENABLE right after INITIALIZE — before the PHY's ~2-3 s
		 * auto-negotiation finishes — so we must NOT gate this on the instantaneous
		 * eth_link_up() (it would read "down", and NetX would then never transmit a
		 * single frame). Report up optimistically, as the RAM driver / ST drivers do;
		 * the MAC is already RX/TX-enabled, so traffic flows once the PHY settles.
		 * GET_STATUS reports the live PHY state. Re-arm RX in case of a prior DISABLE. */
		/* Frames that arrived while DISABLED sit CPU-owned in the ring: drain and
		 * DROP them (they were captured while the interface was down — delivering
		 * them now would replay stale ARP/IP traffic), which also recycles the
		 * descriptors. Without this, a disable across a >=ring-size burst leaves
		 * the RX DMA suspended on RBU with no future RI possible (recycle only
		 * happens on drain, drain only on RI) — RX dead for good. Safe scratch:
		 * all driver entry is serialized under the IP protection mutex. */
		if (nx_driver_initialized) {
			while (eth_recv(nx_driver_txlin, sizeof(nx_driver_txlin)) != 0u) {
			}
		}
		eth_set_rx_callback(nx_driver_rx_signal);
		interface_ptr->nx_interface_link_up = NX_TRUE;
		break;

	case NX_LINK_DISABLE:
		/* NetX documents DISABLE as disabling the physical interface: stop feeding
		 * RX up the stack (frames land in the ring and age out; TX is refused by
		 * the !initialized guard only on UNINITIALIZE, not here — the IP layer
		 * already gates sends on nx_interface_link_up). */
		eth_set_rx_callback(0);
		interface_ptr->nx_interface_link_up = NX_FALSE;
		break;

	case NX_LINK_RARP_SEND:
		/* RARP unsupported (nothing enables it; routing it would only link dead
		 * NetX code) — but a *_SEND command hands us the packet, so declining it
		 * must still release it or every attempt leaks one pool packet. */
		nx_packet_transmit_release(driver_req_ptr->nx_ip_driver_packet);
		driver_req_ptr->nx_ip_driver_status = NX_UNHANDLED_COMMAND;
		break;

	case NX_LINK_PACKET_SEND:
	case NX_LINK_PACKET_BROADCAST:
	case NX_LINK_ARP_SEND:
	case NX_LINK_ARP_RESPONSE_SEND: {
		if (!nx_driver_initialized) {
			nx_packet_transmit_release(driver_req_ptr->nx_ip_driver_packet);
			driver_req_ptr->nx_ip_driver_status = NX_NOT_SUCCESSFUL;
			break;
		}
		UINT et;
		UINT cmd = driver_req_ptr->nx_ip_driver_command;
		if (cmd == NX_LINK_ARP_SEND || cmd == NX_LINK_ARP_RESPONSE_SEND) {
			et = NX_ETHERNET_ARP;
		} else if (driver_req_ptr->nx_ip_driver_packet->nx_packet_ip_version == 4) {
			et = NX_ETHERNET_IP;
		} else {
			et = NX_ETHERNET_IPV6;
		}
		nx_driver_ethernet_send(driver_req_ptr, et);
		break;
	}

	case NX_LINK_DEFERRED_PROCESSING:
		nx_driver_receive();
		break;

	case NX_LINK_GET_STATUS: {
		/* LIVE PHY status (not the latched ENABLE flag) — and eth_link_up() also
		 * re-syncs MACCR speed/duplex when it finds the link up, which covers the
		 * boot-without-cable fallback. Keep the interface flag in step so
		 * nx_ip_status_check sees reality too. */
		UINT up = eth_link_up() ? NX_TRUE : NX_FALSE;
		interface_ptr->nx_interface_link_up = up;
		*(driver_req_ptr->nx_ip_driver_return_ptr) = up;
		break;
	}

	case NX_LINK_SET_PHYSICAL_ADDRESS: {
		/* Reprogram the address FILTER only — a full eth_init here would soft-reset
		 * the MAC while the caller holds the IP mutex (~4 s stack freeze), discard
		 * live rings, and wipe MACPFR multicast state. */
		nx_driver_mac[0] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_msw >> 8);
		nx_driver_mac[1] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_msw);
		nx_driver_mac[2] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw >> 24);
		nx_driver_mac[3] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw >> 16);
		nx_driver_mac[4] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw >> 8);
		nx_driver_mac[5] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw);
		if (nx_driver_initialized) {
			eth_set_mac(nx_driver_mac);
		}
		break;
	}

	case NX_LINK_MULTICAST_JOIN:
		/* Coarse hardware filter: pass ALL multicast from the first join on;
		 * NetX filters per-group in software. LEAVE stays a no-op (the coarse
		 * filter has no per-address state to undo). */
		eth_multicast_all();
		break;

	case NX_LINK_MULTICAST_LEAVE:
		break;

	case NX_LINK_UNINITIALIZE:
	case NX_LINK_INTERFACE_DETACH:
		/* Detach the ISR from NetX: a frame arriving after teardown must not run
		 * deferred processing on a stale NX_IP. (Full MAC/NVIC teardown is out of
		 * scope — blobly targets create the IP instance once, statically, at boot.) */
		eth_set_rx_callback(0);
		nx_driver_initialized = 0;
		break;

	default:
		driver_req_ptr->nx_ip_driver_status = NX_UNHANDLED_COMMAND;
		break;
	}
}
