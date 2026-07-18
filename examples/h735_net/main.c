/* examples/h735_net/main.c — TCP/IP P1+P2 on the STM32H735G-DK: ThreadX + NetX
 * Duo + the register-level ETH driver (boards/h735dk/eth.c) + the NetX glue
 * (net/nx_driver_stm32h7.c).
 *
 * P1 (BENCH-VERIFIED 2026-07-18): link + ARP + ICMP, 0% loss, ~1 ms RTT.
 * P2 (REQ-NET-005, docs/net.md): the UDP datagram service — an echo socket on
 * UDP_ECHO_PORT (prove RX+TX + the socket API: `nc -u <board> 5005`) and a 1 Hz
 * telemetry broadcast on UDP_TELEM_PORT (the bench counters as one line of text;
 * listen with `nc -ul 5006`). Deliberately a plain C ThreadX app, NOT a
 * loom2v-generated image — it proves the driver + stack on silicon; the config-
 * generated net partition comes later (docs/net.md "How it fits blobly"). */
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

/* P2 UDP: echo returns every datagram to its sender; telemetry broadcasts the
 * bench counters to the subnet once a second (config-free host side: nc -ul). */
#define UDP_ECHO_PORT  5005
#define UDP_TELEM_PORT 5006
#define TELEM_DEST     (IP_ADDR | ~IP_MASK) /* subnet broadcast, follows IP config */

/* P3 TCP (REQ-NET-006): a byte-stream echo server — one connection at a time
 * (`nc 192.168.0.50 5007`), re-listens after each disconnect. */
#define TCP_ECHO_PORT  5007
#define TCP_WINDOW     2048 /* small: echo never buffers much, pool is 12 packets */

/* --- static memory (no heap; REQ-NET-001/002). Packet payload rounds the 1514
 * frame up so an Ethernet frame + NetX overhead fits one packet. */
#define POOL_PAYLOAD 1568u
#define POOL_COUNT   12u
static UCHAR pool_mem[POOL_COUNT * (POOL_PAYLOAD + sizeof(NX_PACKET))]
	__attribute__((aligned(4)));
static UCHAR ip_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR arp_cache[1024] __attribute__((aligned(4)));
static UCHAR ping_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR echo_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR tcp_thread_stack[2048] __attribute__((aligned(8)));

static NX_PACKET_POOL pool;
static NX_IP ip;
static TX_THREAD ping_thread;
static TX_THREAD echo_thread;
static TX_THREAD tcp_thread;
static NX_UDP_SOCKET echo_sock;
static NX_UDP_SOCKET telem_sock;
static NX_TCP_SOCKET tcp_sock;

/* bench-observable outcome (read over SWD; no UART on the DK's default wiring). */
volatile ULONG net_ping_ok;
volatile ULONG net_ping_fail;
volatile ULONG net_link_up;
volatile ULONG net_udp_echoed;   /* datagrams echoed back */
volatile ULONG net_telem_sent;   /* telemetry broadcasts sent */
volatile ULONG net_tcp_echoed;   /* TCP segments echoed back */
volatile ULONG net_tcp_conns;    /* TCP connections accepted */

/* driver counters (boards/h735dk/eth.c), reported in the telemetry line. */
extern volatile unsigned int eth_rx_count, eth_tx_count, eth_tx_drops;

/* u32 -> decimal, returns chars written (no libc printf in this image). */
static UINT u32_dec(char *dst, ULONG v) {
	char tmp[10];
	UINT n = 0;
	do {
		tmp[n++] = (char)('0' + (v % 10u));
		v /= 10u;
	} while (v != 0u);
	for (UINT i = 0; i < n; i++) {
		dst[i] = tmp[n - 1u - i];
	}
	return n;
}

extern VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr);

static UINT append(char *dst, UINT o, const char *s) {
	while (*s != '\0') {
		dst[o++] = *s++;
	}
	return o;
}

/* UDP echo (REQ-NET-005 receive+send): every datagram goes straight back to its
 * sender — the standard `nc -u <board> 5005` bench check. */
static void echo_entry(ULONG arg) {
	(void)arg;
	nx_udp_socket_create(&ip, &echo_sock, "echo", NX_IP_NORMAL, NX_DONT_FRAGMENT,
	                     0x80, 5);
	nx_udp_socket_bind(&echo_sock, UDP_ECHO_PORT, NX_WAIT_FOREVER);
	for (;;) {
		NX_PACKET *p = NX_NULL;
		if (nx_udp_socket_receive(&echo_sock, &p, NX_WAIT_FOREVER) != NX_SUCCESS) {
			continue;
		}
		ULONG src_ip;
		UINT src_port;
		nx_udp_source_extract(p, &src_ip, &src_port);
		if (nx_udp_socket_send(&echo_sock, p, src_ip, src_port) == NX_SUCCESS) {
			net_udp_echoed++; /* count only what was actually handed to TX */
		} else {
			nx_packet_release(p); /* send takes ownership only on success */
		}
	}
}

/* TCP echo (REQ-NET-006, the reliable-stream service): single connection at a
 * time, every received segment sent straight back, re-listen after disconnect —
 * `nc <board> 5007` from the host. */
static void tcp_entry(ULONG arg) {
	(void)arg;
	nx_tcp_socket_create(&ip, &tcp_sock, "tcp-echo", NX_IP_NORMAL, NX_DONT_FRAGMENT,
	                     0x80, TCP_WINDOW, NX_NULL, NX_NULL);
	nx_tcp_server_socket_listen(&ip, TCP_ECHO_PORT, &tcp_sock, 5, NX_NULL);
	for (;;) {
		if (nx_tcp_server_socket_accept(&tcp_sock, NX_WAIT_FOREVER) == NX_SUCCESS) {
			net_tcp_conns++;
			NX_PACKET *p = NX_NULL;
			while (nx_tcp_socket_receive(&tcp_sock, &p, NX_WAIT_FOREVER) == NX_SUCCESS) {
				if (nx_tcp_socket_send(&tcp_sock, p, NX_IP_PERIODIC_RATE) == NX_SUCCESS) {
					net_tcp_echoed++;
				} else {
					nx_packet_release(p); /* send takes ownership only on success */
					break;
				}
			}
			/* peer closed (receive fails NX_NOT_CONNECTED) or send failed. */
			nx_tcp_socket_disconnect(&tcp_sock, NX_IP_PERIODIC_RATE);
		}
		nx_tcp_server_socket_unaccept(&tcp_sock);
		nx_tcp_server_socket_relisten(&ip, TCP_ECHO_PORT, &tcp_sock);
	}
}

static void ping_entry(ULONG arg) {
	(void)arg;
	ULONG status_bits;

	/* wait for the driver to report link-up (auto-negotiation settled). */
	while (nx_ip_status_check(&ip, NX_IP_LINK_ENABLED, &status_bits, PING_WAIT) != NX_SUCCESS) {
		net_link_up = 0;
	}
	net_link_up = 1;

	/* the telemetry sender's socket (bound so the stack has a source port). */
	nx_udp_socket_create(&ip, &telem_sock, "telem", NX_IP_NORMAL, NX_DONT_FRAGMENT,
	                     0x80, 5);
	nx_udp_socket_bind(&telem_sock, UDP_TELEM_PORT, NX_WAIT_FOREVER);

	for (;;) {
		/* Live link poll (driver GET_STATUS -> PHY BSR): keeps net_link_up honest
		 * (the ENABLE flag is optimistic and would read 1 even with no cable) AND
		 * drives the driver's down->up MACCR speed/duplex resync — without this
		 * poll a board booted cableless would stay on the 100M/full guess forever. */
		ULONG live = NX_FALSE;
		nx_ip_driver_direct_command(&ip, NX_LINK_GET_STATUS, &live);
		net_link_up = live;

		/* Telemetry FIRST, ping after: a dark gateway makes nx_icmp_ping block for
		 * PING_WAIT, and telemetry sent before it stays prompt each iteration (the
		 * cadence still stretches to ~3 s while pings time out — acceptable for a
		 * bench diagnostic; a separate timer thread for perfect 1 Hz would be bloat).
		 * The counters line is the CpuLoad-over-CAN idea carried to UDP.
		 * Worst case: 44 literal chars + 7 x 10-digit counters + '\n' = 115 bytes. */
		char line[128];
		UINT o = 0;
		o = append(line, o, "blobly ok=");
		o += u32_dec(line + o, net_ping_ok);
		o = append(line, o, " fail=");
		o += u32_dec(line + o, net_ping_fail);
		o = append(line, o, " rx=");
		o += u32_dec(line + o, eth_rx_count);
		o = append(line, o, " tx=");
		o += u32_dec(line + o, eth_tx_count);
		o = append(line, o, " drops=");
		o += u32_dec(line + o, eth_tx_drops);
		o = append(line, o, " echoed=");
		o += u32_dec(line + o, net_udp_echoed);
		o = append(line, o, " tcp=");
		o += u32_dec(line + o, net_tcp_echoed);
		line[o++] = '\n';
		NX_PACKET *tp = NX_NULL;
		if (nx_packet_allocate(&pool, &tp, NX_UDP_PACKET, NX_NO_WAIT) == NX_SUCCESS) {
			if (nx_packet_data_append(tp, line, o, &pool, NX_NO_WAIT) == NX_SUCCESS &&
			    nx_udp_socket_send(&telem_sock, tp, TELEM_DEST, UDP_TELEM_PORT) == NX_SUCCESS) {
				net_telem_sent++;
			} else {
				nx_packet_release(tp);
			}
		}

		/* Drain anything RECEIVED on the telemetry port (other boards' broadcasts,
		 * port scans): the socket queues up to its depth and nothing else reads it,
		 * so unread datagrams would pin pool packets forever (5 of 12!). */
		{
			NX_PACKET *junk = NX_NULL;
			while (nx_udp_socket_receive(&telem_sock, &junk, NX_NO_WAIT) == NX_SUCCESS) {
				nx_packet_release(junk);
			}
		}

		NX_PACKET *resp = NX_NULL;
		UINT s = nx_icmp_ping(&ip, PING_DEST, "blobly-p1", 9, &resp, PING_WAIT);
		if (s == NX_SUCCESS) {
			net_ping_ok++;
			nx_packet_release(resp);
		} else {
			net_ping_fail++;
		}

		tx_thread_sleep(NX_IP_PERIODIC_RATE); /* 1 s cadence */
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
	nx_udp_enable(&ip); /* P2: the datagram service */
	nx_tcp_enable(&ip); /* P3: the reliable-stream service */
	nx_ip_gateway_address_set(&ip, GATEWAY);

	tx_thread_create(&ping_thread, "ping", ping_entry, 0,
	                 ping_thread_stack, sizeof(ping_thread_stack),
	                 3, 3, TX_NO_TIME_SLICE, TX_AUTO_START);
	tx_thread_create(&echo_thread, "udp-echo", echo_entry, 0,
	                 echo_thread_stack, sizeof(echo_thread_stack),
	                 4, 4, TX_NO_TIME_SLICE, TX_AUTO_START);
	/* priority 5, BELOW udp-echo(4): a TCP client streaming back-to-back data
	 * keeps this thread runnable (receive returns immediately on queued data),
	 * and at equal priority with no time slice it would starve the UDP echo. */
	tx_thread_create(&tcp_thread, "tcp-echo", tcp_entry, 0,
	                 tcp_thread_stack, sizeof(tcp_thread_stack),
	                 5, 5, TX_NO_TIME_SLICE, TX_AUTO_START);
}

/* This image has no CAN, but the shared vector table (boards/common/vectors.S)
 * wires IRQ19 to a strong FDCAN1_IT0_IRQHandler that every image must provide — a
 * trivial stub here, exactly as the CAN-less m4_glue.c does. The FDCAN interrupt
 * is never enabled, so it never fires. */
void FDCAN1_IT0_IRQHandler(void) {
}

/* NetX's UDP/TCP bind uses rand() (NX_RAND) for ephemeral ports; newlib-nano's
 * rand drags the reent/malloc/_sbrk chain into this no-alloc image (link error:
 * _sbrk needs `end`). A strong xorshift32 here keeps newlib's out entirely —
 * port randomization needs no cryptographic quality. */
static unsigned int rand_state = 0x2624B0B1u; /* nonzero seed */
int rand(void) {
	rand_state ^= rand_state << 13;
	rand_state ^= rand_state >> 17;
	rand_state ^= rand_state << 5;
	return (int)(rand_state & 0x7FFFFFFFu);
}
void srand(unsigned int seed) {
	rand_state = (seed != 0u) ? seed : 0x2624B0B1u;
}

int main(void) {
	board_clock_init(); /* 550 MHz PLL1 + I-cache */
	tx_kernel_enter();  /* -> tx_application_define; never returns */
	return 0;
}
