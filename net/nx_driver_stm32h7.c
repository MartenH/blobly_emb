/* net/nx_driver_stm32h7.c — NetX Duo network driver for the STM32H735 ETH MAC.
 *
 * The thin glue between NetX Duo and boards/h735dk/eth.c: it implements the
 * NX_IP_DRIVER command dispatch (the same contract as the vendored RAM driver,
 * third_party/netxduo/common/src/nx_ram_network_driver.c) and translates it into
 * eth_init/eth_send/eth_recv calls. Register-level details live entirely in eth.c;
 * this file knows nothing about the H735's registers.
 *
 * TX: NetX prepends the Ethernet header into the packet chain (the PACKET_SEND
 * case below), so we just linearise the chain and hand the bytes to eth_send.
 * RX: the ETH ISR (eth_isr) signals deferred processing; NX_LINK_DEFERRED_PROCESSING
 * drains eth_recv, allocates an NX_PACKET, and routes by EtherType — mirroring the
 * RAM driver's _nx_ram_network_driver_receive.
 *
 * *** BENCH-UNVERIFIED on H735 *** — see eth.c. Scope = P1 (link + IPv4 + ICMP). */
#include "nx_api.h"
#include "eth.h"

/* Local EtherType/frame constants — the RAM driver keeps its own copies too
 * (they are not exported from nx_api.h). */
#define NX_ETHERNET_IP   0x0800u
#define NX_ETHERNET_ARP  0x0806u
#define NX_ETHERNET_RARP 0x8035u
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
			return; /* pool exhausted — drop the backlog, DMA keeps its buffers */
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
		} else if (ether_type == NX_ETHERNET_RARP) {
			packet->nx_packet_prepend_ptr += NX_ETHERNET_SIZE;
			packet->nx_packet_length -= NX_ETHERNET_SIZE;
			_nx_rarp_packet_deferred_receive(nx_driver_ip, packet);
		} else {
			nx_packet_release(packet); /* unknown EtherType */
		}
	}
}

/* --- linearise a (possibly chained) NX_PACKET and transmit it. */
static void nx_driver_transmit(NX_PACKET *packet) {
	ULONG total = packet->nx_packet_length;
	if (total > sizeof(nx_driver_txlin)) {
		nx_packet_transmit_release(packet);
		return;
	}
	ULONG off = 0;
	for (NX_PACKET *p = packet; p != NX_NULL; p = p->nx_packet_next) {
		ULONG chunk = (ULONG)(p->nx_packet_append_ptr - p->nx_packet_prepend_ptr);
		if (off + chunk > total) {
			chunk = total - off;
		}
		for (ULONG j = 0; j < chunk; j++) {
			nx_driver_txlin[off + j] = p->nx_packet_prepend_ptr[j];
		}
		off += chunk;
		if (off >= total) {
			break;
		}
	}
	(void)eth_send(nx_driver_txlin, off);
	nx_packet_transmit_release(packet);
}

/* --- prepend the Ethernet header NetX asked us to build, then transmit.
 * Identical framing to the RAM driver's non-VLAN PACKET_SEND path. */
static void nx_driver_ethernet_send(NX_IP_DRIVER *req, UINT ether_type) {
	NX_PACKET *packet = req->nx_ip_driver_packet;

	packet->nx_packet_prepend_ptr -= NX_ETHERNET_SIZE;
	packet->nx_packet_length += NX_ETHERNET_SIZE;

	ULONG *frame = (ULONG *)(packet->nx_packet_prepend_ptr - 2);
	*frame = req->nx_ip_driver_physical_address_msw;
	*(frame + 1) = req->nx_ip_driver_physical_address_lsw;
	*(frame + 2) = (nx_driver_interface->nx_interface_physical_address_msw << 16)
	             | (nx_driver_interface->nx_interface_physical_address_lsw >> 16);
	*(frame + 3) = (nx_driver_interface->nx_interface_physical_address_lsw << 16) | ether_type;
	NX_CHANGE_ULONG_ENDIAN(*(frame));
	NX_CHANGE_ULONG_ENDIAN(*(frame + 1));
	NX_CHANGE_ULONG_ENDIAN(*(frame + 2));
	NX_CHANGE_ULONG_ENDIAN(*(frame + 3));

	nx_driver_transmit(packet);
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
		 * GET_STATUS still reports the live PHY state. */
		interface_ptr->nx_interface_link_up = NX_TRUE;
		break;

	case NX_LINK_DISABLE:
		interface_ptr->nx_interface_link_up = NX_FALSE;
		break;

	case NX_LINK_PACKET_SEND:
	case NX_LINK_PACKET_BROADCAST:
	case NX_LINK_ARP_SEND:
	case NX_LINK_ARP_RESPONSE_SEND:
	case NX_LINK_RARP_SEND: {
		if (!nx_driver_initialized) {
			nx_packet_transmit_release(driver_req_ptr->nx_ip_driver_packet);
			driver_req_ptr->nx_ip_driver_status = NX_NOT_SUCCESSFUL;
			break;
		}
		UINT et;
		UINT cmd = driver_req_ptr->nx_ip_driver_command;
		if (cmd == NX_LINK_ARP_SEND || cmd == NX_LINK_ARP_RESPONSE_SEND) {
			et = NX_ETHERNET_ARP;
		} else if (cmd == NX_LINK_RARP_SEND) {
			et = NX_ETHERNET_RARP;
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

	case NX_LINK_GET_STATUS:
		*(driver_req_ptr->nx_ip_driver_return_ptr) =
		    interface_ptr->nx_interface_link_up ? NX_TRUE : NX_FALSE;
		break;

	case NX_LINK_SET_PHYSICAL_ADDRESS: {
		/* re-program the station MAC and re-init so the MAC filter matches. */
		nx_driver_mac[0] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_msw >> 8);
		nx_driver_mac[1] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_msw);
		nx_driver_mac[2] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw >> 24);
		nx_driver_mac[3] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw >> 16);
		nx_driver_mac[4] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw >> 8);
		nx_driver_mac[5] = (UCHAR)(driver_req_ptr->nx_ip_driver_physical_address_lsw);
		if (nx_driver_initialized) {
			(void)eth_init(nx_driver_mac);
		}
		break;
	}

	/* Benign for a single-MAC-filter P1 driver: promiscuous RX means multicast
	 * groups are already received; the IP layer filters. */
	case NX_LINK_MULTICAST_JOIN:
	case NX_LINK_MULTICAST_LEAVE:
	case NX_LINK_UNINITIALIZE:
	case NX_LINK_INTERFACE_DETACH:
		break;

	default:
		driver_req_ptr->nx_ip_driver_status = NX_UNHANDLED_COMMAND;
		break;
	}
}
