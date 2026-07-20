/* driver/eth NetX backend — the target twin of eth_udp.c, same blob_eth_* ABI
 * (docs/someip.md target rung). The generated eth thread drives the identical
 * contract either side of the silicon line: open the node's static endpoint,
 * send one datagram, drain one datagram nonblocking with the source endpoint
 * and the REAL length reported (a datagram longer than max was truncated into
 * the buffer and must be dropped by the caller, exactly the host MSG_TRUNC
 * semantics; -1 = nothing pending, 0 = a real empty datagram).
 *
 * Bring-up lives in blob_eth_open (first call): NetX init, static pool, IP
 * instance on the STM32H7 driver, ARP/ICMP/UDP, PHY link wait, socket bind,
 * and the 1 Hz link-poll service thread every established H735 loop runs
 * (eth_link_up() resynchronizes MACCR on renegotiation — a cable replug
 * recovers instead of leaving the MAC stale). No heap anywhere (REQ-NET-001/
 * 002): all NetX memory is static, sized here.
 *
 * Not compiled by driver/eth/eth.v (whose #flag pulls the POSIX backend for
 * host builds) — a target image lists this file in its Makefile sources, the
 * same way the CAN backends are selected. */
#include "tx_api.h"
#include "nx_api.h"
#include "eth.h" /* boards/<board>/eth.c: eth_link_up() */

#define POOL_PAYLOAD 1568u
#define POOL_COUNT   8u
static UCHAR pool_mem[POOL_COUNT * (POOL_PAYLOAD + sizeof(NX_PACKET))]
	__attribute__((aligned(4)));
static UCHAR ip_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR arp_cache[1024] __attribute__((aligned(4)));
static UCHAR svc_thread_stack[1024] __attribute__((aligned(8)));

static NX_PACKET_POOL pool;
static NX_IP ip;
static TX_THREAD svc_thread;
static NX_UDP_SOCKET udp_sock;
static int eth_open_done;

/* bench-observable (SWD, openocd not st-util) */
volatile ULONG net_link_up;
volatile ULONG someip_tx_ok;
volatile ULONG someip_tx_fail;

extern VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr);

/* NetX references rand() (NX_RAND); newlib-nano's rand drags reent/malloc/
 * _sbrk into a no-alloc image (bench-paid on h735_net P2). UID-seeded
 * xorshift — no TCP here, so no ISN-security stakes. */
static unsigned int rand_state;
int rand(void) {
	if (rand_state == 0u) {
		const volatile unsigned int *uid = (const volatile unsigned int *)0x1FF1E800u;
		rand_state = uid[0] ^ uid[1] ^ uid[2];
		if (rand_state == 0u) {
			rand_state = 0x2624B0B1u;
		}
	}
	rand_state ^= rand_state << 13;
	rand_state ^= rand_state >> 17;
	rand_state ^= rand_state << 5;
	return (int)(rand_state & 0x7FFFFFFFu);
}
void srand(unsigned int seed) {
	rand_state = (seed != 0u) ? seed : 0x2624B0B1u;
}

static void svc_entry(ULONG arg) {
	(void)arg;
	for (;;) {
		net_link_up = eth_link_up();
		tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND);
	}
}

/* parse one dotted-quad octet run; returns the IP or 0 on a malformed string
 * (0.0.0.0 is not a bindable static endpoint here, so 0 doubles as failure). */
static ULONG parse_ip4(const char *s) {
	ULONG oct[4] = {0, 0, 0, 0};
	int i = 0;
	for (const char *p = s; *p != '\0'; p++) {
		if (*p == '.') {
			if (++i > 3) {
				return 0;
			}
		} else if (*p >= '0' && *p <= '9') {
			oct[i] = oct[i] * 10u + (ULONG)(*p - '0');
			if (oct[i] > 255u) {
				return 0;
			}
		} else {
			return 0;
		}
	}
	if (i != 3) {
		return 0;
	}
	return IP_ADDRESS(oct[0], oct[1], oct[2], oct[3]);
}

/* blob_eth_open: full bring-up + bind of the node's static endpoint. Blocks
 * until the PHY link is up (events into a down link are just lost — the
 * bench's whole point is the first events). Returns 0, or -1 on failure.
 * The gateway is the .1 of the node's own /24 — static-endpoint deployments
 * (REQ-NET-017) put the bench peer on the same segment; a routed peer would
 * make the gateway config, not convention. */
int blob_eth_open(const char *bind_ip, unsigned short port) {
	if (eth_open_done) {
		return -1; /* one endpoint per image (the [someip] singleton) */
	}
	ULONG addr = parse_ip4(bind_ip);
	if (addr == 0u) {
		return -1;
	}
	nx_system_initialize();
	if (nx_packet_pool_create(&pool, "eth-pool", POOL_PAYLOAD, pool_mem, sizeof(pool_mem)) != NX_SUCCESS) {
		return -1;
	}
	if (nx_ip_create(&ip, "eth-ip", addr, 0xFFFFFF00UL, &pool, nx_driver_stm32h7,
	                 ip_thread_stack, sizeof(ip_thread_stack), 1) != NX_SUCCESS) {
		return -1;
	}
	nx_arp_enable(&ip, arp_cache, sizeof(arp_cache));
	nx_icmp_enable(&ip); /* the board stays pingable — the P1 bench habit */
	nx_udp_enable(&ip);
	nx_ip_gateway_address_set(&ip, (addr & 0xFFFFFF00UL) | 1u);
	while (!eth_link_up()) {
		tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND / 10);
	}
	net_link_up = 1;
	if (nx_udp_socket_create(&ip, &udp_sock, "eth-udp", NX_IP_NORMAL,
	                         NX_DONT_FRAGMENT, 0x80, 8) != NX_SUCCESS) {
		return -1;
	}
	if (nx_udp_socket_bind(&udp_sock, port, TX_WAIT_FOREVER) != NX_SUCCESS) {
		return -1;
	}
	tx_thread_create(&svc_thread, "eth-svc", svc_entry, 0,
	                 svc_thread_stack, sizeof(svc_thread_stack),
	                 5, 5, TX_NO_TIME_SLICE, TX_AUTO_START);
	eth_open_done = 1;
	return 0;
}

/* blob_eth_send: one datagram to ip[4]:port. 0 = handed to the stack. The
 * caller's loop drains rx itself, so no hidden drain here (the tx-only glue's
 * pool-starvation guard moved to the generated drain). */
int blob_eth_send(int fd, const unsigned char *ip4, unsigned short port,
                  const unsigned char *buf, int len) {
	(void)fd;
	NX_PACKET *pkt;
	if (nx_packet_allocate(&pool, &pkt, NX_UDP_PACKET, TX_NO_WAIT) != NX_SUCCESS) {
		someip_tx_fail++;
		return -1;
	}
	if (nx_packet_data_append(pkt, (VOID *)buf, (ULONG)len, &pool, TX_NO_WAIT) != NX_SUCCESS) {
		nx_packet_release(pkt);
		someip_tx_fail++;
		return -1;
	}
	ULONG dst = IP_ADDRESS(ip4[0], ip4[1], ip4[2], ip4[3]);
	if (nx_udp_socket_send(&udp_sock, pkt, dst, port) != NX_SUCCESS) {
		nx_packet_release(pkt);
		someip_tx_fail++;
		return -1;
	}
	someip_tx_ok++;
	return 0;
}

/* blob_eth_recv: one datagram, nonblocking — the host contract exactly:
 * returns the REAL datagram length (may exceed max; only max bytes copied,
 * caller drops the truncated datagram), src ip/port filled; -1 = nothing
 * pending; 0 = a real empty datagram (counted by the caller, not idle). */
int blob_eth_recv(int fd, unsigned char *ip4, unsigned short *port,
                  unsigned char *buf, int max) {
	(void)fd;
	NX_PACKET *pkt;
	if (nx_udp_socket_receive(&udp_sock, &pkt, TX_NO_WAIT) != NX_SUCCESS) {
		return -1;
	}
	ULONG src_ip = 0;
	UINT src_port = 0;
	nx_udp_source_extract(pkt, &src_ip, &src_port);
	ip4[0] = (unsigned char)(src_ip >> 24);
	ip4[1] = (unsigned char)(src_ip >> 16);
	ip4[2] = (unsigned char)(src_ip >> 8);
	ip4[3] = (unsigned char)(src_ip);
	*port = (unsigned short)src_port;
	ULONG total = 0;
	nx_packet_length_get(pkt, &total);
	ULONG copied = 0;
	nx_packet_data_extract_offset(pkt, 0, buf, (ULONG)max, &copied);
	nx_packet_release(pkt);
	return (int)total;
}

void blob_eth_close(int fd) {
	(void)fd;
	if (eth_open_done) {
		nx_udp_socket_unbind(&udp_sock);
		nx_udp_socket_delete(&udp_sock);
		eth_open_done = 0;
	}
}
