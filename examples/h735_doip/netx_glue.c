/* examples/h735_doip/netx_glue.c — the C transport half of the DoIP image: ThreadX
 * + NetX bring-up (pool/IP/ARP/ICMP/UDP/TCP + the ETH driver) and the four-call
 * byte-pipe seam the V side (main.v / comm.doip) drives. NO protocol logic here —
 * DoIP framing and UDS live in tested V code.
 *
 * Ports per ISO 13400: TCP 13400 (diagnostic data), UDP 13400 (announcement). */
#include "tx_api.h"
#include "nx_api.h"
#include "eth.h"

#define IP_ADDR    IP_ADDRESS(192, 168, 0, 50)
#define IP_MASK    0xFFFFFF00UL
#define GATEWAY    IP_ADDRESS(192, 168, 0, 1)
#define DOIP_PORT  13400
#define TCP_WINDOW 2048

/* --- static memory (no heap; REQ-NET-001/002) --- */
#define POOL_PAYLOAD 1568u
#define POOL_COUNT   12u
static UCHAR pool_mem[POOL_COUNT * (POOL_PAYLOAD + sizeof(NX_PACKET))]
	__attribute__((aligned(4)));
static UCHAR ip_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR arp_cache[1024] __attribute__((aligned(4)));
static UCHAR app_thread_stack[4096] __attribute__((aligned(8))); /* runs the V loop */

static NX_PACKET_POOL pool;
static NX_IP ip;
static TX_THREAD app_thread;
static NX_TCP_SOCKET tcp_sock;
static NX_UDP_SOCKET udp_sock;
static UINT tcp_connected;

/* bench-observable (SWD) */
volatile ULONG net_link_up;
volatile ULONG doip_rx_bytes;
volatile ULONG doip_tx_bytes;

extern VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr);
extern void blobly_doip_run(void); /* the V server loop (main.v) */

/* NetX bind/ISN use rand() (NX_RAND); newlib-nano's rand drags reent/malloc/
 * _sbrk into this no-alloc image. TRNG-seeded xorshift, same recipe as
 * examples/h735_net (predictable ISNs would make TCP sessions spoofable). */
#define RCC_CR_R       (*(volatile unsigned int *)0x58024400u)
#define RCC_D2CCIP2R_R (*(volatile unsigned int *)0x58024454u)
#define RCC_AHB2ENR_R  (*(volatile unsigned int *)0x580244DCu)
#define RNG_CR_R       (*(volatile unsigned int *)0x48021800u)
#define RNG_SR_R       (*(volatile unsigned int *)0x48021804u)
#define RNG_DR_R       (*(volatile unsigned int *)0x48021808u)
#define SYST_VAL_R     (*(volatile unsigned int *)0xE000E018u)

static unsigned int rand_state = 0x2624B0B1u;

static void trng_seed(void) {
	RCC_CR_R |= (1u << 12);
	for (unsigned int t = 0; (RCC_CR_R & (1u << 13)) == 0u; t++) {
		if (t > 2000000u) {
			goto fallback;
		}
	}
	RCC_D2CCIP2R_R &= ~(3u << 8);
	RCC_AHB2ENR_R |= (1u << 6);
	(void)RCC_AHB2ENR_R;
	RNG_CR_R = (1u << 2);
	for (unsigned int t = 0; (RNG_SR_R & 1u) == 0u; t++) {
		if (t > 200000u) {
			goto fallback;
		}
	}
	rand_state = RNG_DR_R;
	if (rand_state != 0u) {
		return;
	}
fallback: {
	const volatile unsigned int *uid = (const volatile unsigned int *)0x1FF1E800u;
	rand_state = uid[0] ^ uid[1] ^ uid[2] ^ SYST_VAL_R;
	if (rand_state == 0u) {
		rand_state = 0x2624B0B1u;
	}
}
}

int rand(void) {
	rand_state ^= rand_state << 13;
	rand_state ^= rand_state >> 17;
	rand_state ^= rand_state << 5;
	return (int)(rand_state & 0x7FFFFFFFu);
}
void srand(unsigned int seed) {
	rand_state = (seed != 0u) ? seed : 0x2624B0B1u;
}

/* ---- the seam main.v drives ------------------------------------------------ */

/* net_stream_recv: one call = accept-if-needed + one bounded receive.
 * >0 = data copied to buf; 0 = idle (timeout); -1 = the connection dropped
 * (socket recycled to listening — the V side resets its DoIP session state).
 *
 * accept MUST wait forever, not on timeout_ticks. A timed-out accept runs
 * _nx_tcp_connect_cleanup, which returns the socket to LISTEN without clearing
 * bound_next or repopulating connect_ip; the next accept then takes the
 * LISTEN+bound_next branch and sends the SYN-ACK itself with a null dest IP,
 * tripping the NX_ASSERT in the TCP checksum path. That assert is an infinite
 * tx_thread_sleep run while accept holds nx_ip_protection, so it starves the IP
 * thread forever and wedges RX (bench-paid on the busy internal network; the
 * quiet P1-P3a benches, which accept()-forever, never reached it). timeout_ticks
 * still bounds the receive below, so the idle-link poll keeps running. */
int net_stream_recv(unsigned char *buf, int max, unsigned int timeout_ticks) {
	if (!tcp_connected) {
		if (nx_tcp_server_socket_accept(&tcp_sock, NX_WAIT_FOREVER) != NX_SUCCESS) {
			return 0;
		}
		tcp_connected = 1;
	}
	NX_PACKET *p = NX_NULL;
	UINT s = nx_tcp_socket_receive(&tcp_sock, &p, timeout_ticks);
	if (s == NX_SUCCESS) {
		ULONG got = 0;
		nx_packet_data_extract_offset(p, 0, buf, (ULONG)max, &got);
		nx_packet_release(p);
		doip_rx_bytes += got;
		return (int)got;
	}
	if (s == NX_NO_PACKET) {
		return 0; /* just a timeout, connection still up */
	}
	/* peer closed or error: recycle to listening */
	nx_tcp_socket_disconnect(&tcp_sock, NX_IP_PERIODIC_RATE);
	nx_tcp_server_socket_unaccept(&tcp_sock);
	nx_tcp_server_socket_relisten(&ip, DOIP_PORT, &tcp_sock);
	tcp_connected = 0;
	return -1;
}

int net_stream_send(const unsigned char *buf, int len) {
	NX_PACKET *p = NX_NULL;
	if (nx_packet_allocate(&pool, &p, NX_TCP_PACKET, NX_IP_PERIODIC_RATE) != NX_SUCCESS) {
		return -1;
	}
	if (nx_packet_data_append(p, (void *)buf, (ULONG)len, &pool, NX_IP_PERIODIC_RATE) != NX_SUCCESS ||
	    nx_tcp_socket_send(&tcp_sock, p, NX_IP_PERIODIC_RATE) != NX_SUCCESS) {
		nx_packet_release(p); /* send takes ownership only on success */
		return -1;
	}
	doip_tx_bytes += (ULONG)len;
	return len;
}

void net_udp_broadcast(int port, const unsigned char *buf, int len) {
	NX_PACKET *p = NX_NULL;
	if (nx_packet_allocate(&pool, &p, NX_UDP_PACKET, NX_NO_WAIT) != NX_SUCCESS) {
		return;
	}
	if (nx_packet_data_append(p, (void *)buf, (ULONG)len, &pool, NX_NO_WAIT) != NX_SUCCESS ||
	    nx_udp_socket_send(&udp_sock, p, IP_ADDR | ~IP_MASK, (UINT)port) != NX_SUCCESS) {
		nx_packet_release(p);
	}
}

void net_eid(unsigned char eid[6]) {
	ULONG msw = ip.nx_ip_interface[0].nx_interface_physical_address_msw;
	ULONG lsw = ip.nx_ip_interface[0].nx_interface_physical_address_lsw;
	eid[0] = (unsigned char)(msw >> 8);
	eid[1] = (unsigned char)msw;
	eid[2] = (unsigned char)(lsw >> 24);
	eid[3] = (unsigned char)(lsw >> 16);
	eid[4] = (unsigned char)(lsw >> 8);
	eid[5] = (unsigned char)lsw;
}

void net_link_poll(void) {
	ULONG up = NX_FALSE;
	nx_ip_driver_direct_command(&ip, NX_LINK_GET_STATUS, &up);
	net_link_up = up;
}

/* ---- bring-up -------------------------------------------------------------- */

static void app_entry(ULONG arg) {
	(void)arg;
	ULONG bits;
	while (nx_ip_status_check(&ip, NX_IP_LINK_ENABLED, &bits, 2 * NX_IP_PERIODIC_RATE) != NX_SUCCESS) {
	}
	/* sockets: UDP (announcement source) + the DoIP TCP listener */
	nx_udp_socket_create(&ip, &udp_sock, "doip-udp", NX_IP_NORMAL, NX_DONT_FRAGMENT, 0x80, 5);
	nx_udp_socket_bind(&udp_sock, DOIP_PORT, NX_WAIT_FOREVER);
	nx_tcp_socket_create(&ip, &tcp_sock, "doip-tcp", NX_IP_NORMAL, NX_DONT_FRAGMENT,
	                     0x80, TCP_WINDOW, NX_NULL, NX_NULL);
	nx_tcp_server_socket_listen(&ip, DOIP_PORT, &tcp_sock, 1, NX_NULL);
	blobly_doip_run(); /* the V server loop; never returns */
}

void tx_application_define(void *first_unused_memory) {
	(void)first_unused_memory;
	trng_seed();
	nx_system_initialize();
	nx_packet_pool_create(&pool, "doip-pool", POOL_PAYLOAD, pool_mem, sizeof(pool_mem));
	nx_ip_create(&ip, "doip-ip", IP_ADDR, IP_MASK, &pool, nx_driver_stm32h7,
	             ip_thread_stack, sizeof(ip_thread_stack), 1);
	nx_arp_enable(&ip, arp_cache, sizeof(arp_cache));
	nx_icmp_enable(&ip);
	nx_udp_enable(&ip);
	nx_tcp_enable(&ip);
	nx_ip_gateway_address_set(&ip, GATEWAY);
	tx_thread_create(&app_thread, "doip", app_entry, 0,
	                 app_thread_stack, sizeof(app_thread_stack),
	                 4, 4, TX_NO_TIME_SLICE, TX_AUTO_START);
}

void glue_kernel_enter(void) {
	tx_kernel_enter(); /* -> tx_application_define; never returns */
}

/* shared vector table: this image has no CAN — parked stub (see m4_glue.c). */
void FDCAN1_IT0_IRQHandler(void) {
	for (;;) {
	}
}
