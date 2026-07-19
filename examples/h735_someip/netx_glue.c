/* examples/h735_someip/netx_glue.c — the C transport half of the SOME/IP tx
 * image (docs/someip.md, the NetX bench rung): ThreadX + NetX bring-up
 * (pool/IP/ARP/ICMP/UDP + the ETH driver) and ONE send-seam call the V side
 * drives. NO protocol logic here — the SOME/IP header and payload live in
 * tested V code (comm/someip + main.v).
 *
 * The seam mirrors driver/eth's host contract (ip[4] + port + bytes), so the
 * V loop reads the same either side of the silicon line. */
#include "tx_api.h"
#include "nx_api.h"
#include "eth.h"

#define IP_ADDR   IP_ADDRESS(192, 168, 0, 50)
#define IP_MASK   0xFFFFFF00UL
#define GATEWAY   IP_ADDRESS(192, 168, 0, 1)
#define SRC_PORT  30490u /* the node's static endpoint ([someip].port) */

/* --- static memory (no heap; REQ-NET-001/002) --- */
#define POOL_PAYLOAD 1568u
#define POOL_COUNT   8u
static UCHAR pool_mem[POOL_COUNT * (POOL_PAYLOAD + sizeof(NX_PACKET))]
	__attribute__((aligned(4)));
static UCHAR ip_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR arp_cache[1024] __attribute__((aligned(4)));
static UCHAR app_thread_stack[4096] __attribute__((aligned(8))); /* runs the V loop */

static NX_PACKET_POOL pool;
static NX_IP ip;
static TX_THREAD app_thread;
static NX_UDP_SOCKET udp_sock;

/* bench-observable (SWD, openocd not st-util) */
volatile ULONG net_link_up;
volatile ULONG someip_tx_ok;
volatile ULONG someip_tx_fail;

extern VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr);
extern void blobly_someip_run(void); /* the V event loop (main.v) */

/* NetX references rand() (NX_RAND); newlib-nano's rand drags reent/malloc/
 * _sbrk into this no-alloc image (bench-paid on h735_net P2). UID-seeded
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

/* ---- the seam main.v drives ------------------------------------------------ */

/* net_udp_send: one datagram to ip[4]:port (the driver/eth contract shape).
 * 0 = handed to the stack. Never blocks the caller beyond the packet copy. */
int net_udp_send(const unsigned char *ip4, unsigned short port,
                 const unsigned char *buf, int len) {
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

void net_sleep_ms(int ms) {
	tx_thread_sleep((ULONG)ms * TX_TIMER_TICKS_PER_SECOND / 1000u);
}

/* app thread: wait for the PHY link (events into a down link are just lost —
 * fine for ICMP, silly for a bench whose whole point is the first events),
 * bind the socket, then hand off to the V loop forever. */
static void app_entry(ULONG arg) {
	(void)arg;
	while (!eth_link_up()) {
		tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND / 10);
	}
	net_link_up = 1;
	nx_udp_socket_create(&ip, &udp_sock, "someip", NX_IP_NORMAL,
	                     NX_DONT_FRAGMENT, 0x80, 8);
	nx_udp_socket_bind(&udp_sock, SRC_PORT, TX_WAIT_FOREVER);
	blobly_someip_run(); /* never returns */
}

void tx_application_define(void *first_unused_memory) {
	(void)first_unused_memory;
	nx_system_initialize();
	nx_packet_pool_create(&pool, "someip-pool", POOL_PAYLOAD, pool_mem, sizeof(pool_mem));
	nx_ip_create(&ip, "someip-ip", IP_ADDR, IP_MASK, &pool, nx_driver_stm32h7,
	             ip_thread_stack, sizeof(ip_thread_stack), 1);
	nx_arp_enable(&ip, arp_cache, sizeof(arp_cache));
	nx_icmp_enable(&ip); /* the board stays pingable — the P1 bench habit */
	nx_udp_enable(&ip);
	nx_ip_gateway_address_set(&ip, GATEWAY);
	tx_thread_create(&app_thread, "someip", app_entry, 0,
	                 app_thread_stack, sizeof(app_thread_stack),
	                 4, 4, TX_NO_TIME_SLICE, TX_AUTO_START);
}

void glue_kernel_enter(void) {
	tx_kernel_enter(); /* -> tx_application_define; never returns */
}

/* shared vector table: this image has no CAN — parked stub. */
void FDCAN1_IT0_IRQHandler(void) {
	for (;;) {
	}
}
