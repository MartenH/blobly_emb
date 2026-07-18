/* examples/h735_net/main.c — P1 TCP/IP bring-up on the STM32H735G-DK: ThreadX +
 * NetX Duo + the register-level ETH driver (boards/h735dk/eth.c) + the NetX glue
 * (net/nx_driver_stm32h7.c). Brings the link up, then pings the gateway on a loop.
 *
 * This is the link+IPv4+ICMP milestone (docs/net.md P1) — deliberately a plain C
 * ThreadX app, NOT a loom2v-generated image: no CAN, no FBs, no config codegen. It
 * exists to prove the driver on silicon. Success/failure are exposed as globals
 * (net_ping_ok / net_ping_fail) so the bench can read them over SWD without a UART.
 *
 * BENCH-VERIFIED on the H735-DK 2026-07-18: 0% ping loss both directions, ~1 ms RTT. */
#include "tx_api.h"
#include "nx_api.h"

/* board bring-up (boards/h735dk/board.c) */
extern void board_clock_init(void);

/* Static addressing (no DHCP for P1 — fewer moving parts to bench-debug). Set
 * IP_ADDR/GATEWAY/PING_DEST for the bench subnet. PING_DEST defaults to the
 * gateway (routers answer LAN-side ping; a PC's firewall usually drops inbound
 * echo) — on a direct board<->PC cable, point it at the PC's NIC instead. The
 * reverse test, `ping <IP_ADDR>` FROM the PC, needs no config and exercises the
 * board's full RX+ARP+TX path. */
#define IP_ADDR    IP_ADDRESS(192, 168, 0, 50)
#define IP_MASK    0xFFFFFF00UL              /* /24 */
#define GATEWAY    IP_ADDRESS(192, 168, 0, 1)
#define PING_DEST  GATEWAY
#define PING_WAIT  (2 * NX_IP_PERIODIC_RATE) /* 2 s */

/* --- static memory (no heap; REQ-NET-001/002). Packet payload rounds the 1514
 * frame up so an Ethernet frame + NetX overhead fits one packet. */
#define POOL_PAYLOAD 1568u
#define POOL_COUNT   12u
static UCHAR pool_mem[POOL_COUNT * (POOL_PAYLOAD + sizeof(NX_PACKET))]
	__attribute__((aligned(4)));
static UCHAR ip_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR arp_cache[1024] __attribute__((aligned(4)));
static UCHAR ping_thread_stack[2048] __attribute__((aligned(8)));

static NX_PACKET_POOL pool;
static NX_IP ip;
static TX_THREAD ping_thread;

/* bench-observable outcome (read over SWD; no UART on the DK's default wiring). */
volatile ULONG net_ping_ok;
volatile ULONG net_ping_fail;
volatile ULONG net_link_up;

extern VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr);

static void ping_entry(ULONG arg) {
	(void)arg;
	ULONG status_bits;

	/* wait for the driver to report link-up (auto-negotiation settled). */
	while (nx_ip_status_check(&ip, NX_IP_LINK_ENABLED, &status_bits, PING_WAIT) != NX_SUCCESS) {
		net_link_up = 0;
	}
	net_link_up = 1;

	for (;;) {
		NX_PACKET *resp = NX_NULL;
		UINT s = nx_icmp_ping(&ip, PING_DEST, "blobly-p1", 9, &resp, PING_WAIT);
		if (s == NX_SUCCESS) {
			net_ping_ok++;
			nx_packet_release(resp);
		} else {
			net_ping_fail++;
		}
		tx_thread_sleep(NX_IP_PERIODIC_RATE); /* 1 s between pings */
	}
}

/* ThreadX hands control here after tx_kernel_enter(). */
void tx_application_define(void *first_unused_memory) {
	(void)first_unused_memory;

	nx_system_initialize();

	nx_packet_pool_create(&pool, "blobly-pool", POOL_PAYLOAD, pool_mem, sizeof(pool_mem));

	nx_ip_create(&ip, "blobly-ip", IP_ADDR, IP_MASK, &pool, nx_driver_stm32h7,
	             ip_thread_stack, sizeof(ip_thread_stack), 1);

	nx_arp_enable(&ip, arp_cache, sizeof(arp_cache));
	nx_icmp_enable(&ip);
	nx_ip_gateway_address_set(&ip, GATEWAY);

	tx_thread_create(&ping_thread, "ping", ping_entry, 0,
	                 ping_thread_stack, sizeof(ping_thread_stack),
	                 3, 3, TX_NO_TIME_SLICE, TX_AUTO_START);
}

/* This image has no CAN, but the shared vector table (boards/common/vectors.S)
 * wires IRQ19 to a strong FDCAN1_IT0_IRQHandler that every image must provide — a
 * trivial stub here, exactly as the CAN-less m4_glue.c does. The FDCAN interrupt
 * is never enabled, so it never fires. */
void FDCAN1_IT0_IRQHandler(void) {
}

int main(void) {
	board_clock_init(); /* 550 MHz PLL1 + I-cache */
	tx_kernel_enter();  /* -> tx_application_define; never returns */
	return 0;
}
