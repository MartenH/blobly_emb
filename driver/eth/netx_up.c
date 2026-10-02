/* driver/eth/netx_up.c — the ONE NetX bring-up of a target image (netx_up.h). All memory static
 * (REQ-NET-001/002). Listed in the image by gen/loom_build.mk whenever the node has an eth bus
 * or [doip]. */
#include "tx_api.h"
#include "nx_api.h"
#include "ip4.h"
#include "netx_up.h"

/* the pool is sized by what the image carries (gen/loom_build.mk's LOOM_NET_DEFS): SOME/IP 8,
 * DoIP 12, both 16 — every socket queue, the TCP window and the driver's RX refill draw on it */
#ifndef BLOB_NET_POOL_COUNT
#define BLOB_NET_POOL_COUNT 8u
#endif
#define POOL_PAYLOAD 1568u
#define POOL_COUNT   BLOB_NET_POOL_COUNT
static UCHAR pool_mem[POOL_COUNT * (POOL_PAYLOAD + sizeof(NX_PACKET))] __attribute__((aligned(4)));
static UCHAR ip_thread_stack[2048] __attribute__((aligned(8)));
static UCHAR arp_cache[1024] __attribute__((aligned(4)));

static NX_PACKET_POOL pool;
static NX_IP ip;
static ULONG ip_addr;
static int up; /* 0 = not yet, 1 = up, -1 = failed */

volatile ULONG net_link_up;

extern VOID nx_driver_stm32h7(NX_IP_DRIVER *driver_req_ptr);

/* ---- rand: NetX's NX_RAND ------------------------------------------------------------------
 * newlib-nano's rand drags reent/malloc/_sbrk into a no-alloc image. xorshift; once seeded from
 * the TRNG, every draw also folds in a fresh TRNG word when one is ready — a bare xorshift gives
 * its state away in one output, so a TCP sequence number seen would predict the next. A read only
 * takes a word the RNG already holds: no wait, no recovery (diag_sa_seed owns that). */
#define RNG_SR_R (*(volatile unsigned int *)0x48021804u)
#define RNG_DR_R (*(volatile unsigned int *)0x48021808u)
static unsigned int rand_state;
static volatile int seeded;
static int trng_on;

int rand(void) {
	if (rand_state == 0u) {
		/* unseeded (a SOME/IP-only node, which opens no TCP): the chip id */
		const volatile unsigned int *uid = (const volatile unsigned int *)0x1FF1E800u;
		rand_state = uid[0] ^ uid[1] ^ uid[2];
		if (rand_state == 0u) {
			rand_state = 0x2624B0B1u;
		}
	}
	if (trng_on) {
		unsigned int sr = RNG_SR_R;
		if ((sr & 1u) && !(sr & 6u)) { /* DRDY, no seed or clock error */
			rand_state ^= RNG_DR_R;
			if (rand_state == 0u) {
				rand_state = 0x2624B0B1u;
			}
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

/* seed 0 = no TRNG word: the chip id and SysTick's current count stand in — distinct per board,
 * barely per boot, and not secret; no TRNG words are folded in either */
void blob_net_seed(unsigned int seed) {
	trng_on = seed != 0u;
	if (seed == 0u) {
		const volatile unsigned int *uid = (const volatile unsigned int *)0x1FF1E800u;
		seed = uid[0] ^ uid[1] ^ uid[2] ^ *(volatile unsigned int *)0xE000E018u;
	}
	srand(seed);
	seeded = 1;
}

int blob_net_seeded(void) {
	return seeded;
}

/* ---- bring-up ------------------------------------------------------------------------------ */

int blob_net_up(const char *addr, unsigned int ip_prio) {
	ULONG a = parse_ip4(addr);
	if (up != 0) {
		return (up > 0 && a == ip_addr) ? 0 : -1;
	}
	up = -1;
	if (a == 0u) {
		return -1;
	}
	ip_addr = a;
	nx_system_initialize();
	if (nx_packet_pool_create(&pool, "net-pool", POOL_PAYLOAD, pool_mem, sizeof(pool_mem)) != NX_SUCCESS) {
		return -1;
	}
	if (nx_ip_create(&ip, "net-ip", a, 0xFFFFFF00UL, &pool, nx_driver_stm32h7,
	                 ip_thread_stack, sizeof(ip_thread_stack), ip_prio) != NX_SUCCESS) {
		return -1;
	}
	/* NetX creates the IP mutex without priority inheritance, and every socket call takes it: a
	 * doip thread (below the FBs) holding it while an FB runs would hold the eth thread's send
	 * behind that FB. With inheritance the holder runs at its highest waiter's priority until it
	 * lets go. Set before any thread can hold it: nothing has a socket yet, and the IP thread's
	 * own start-up, if it has run, did not block holding it. */
	ip.nx_ip_protection.tx_mutex_inherit = TX_INHERIT;
	nx_arp_enable(&ip, arp_cache, sizeof(arp_cache));
	nx_icmp_enable(&ip); /* pingable — the bench habit */
	nx_udp_enable(&ip);
	/* static-endpoint deployments (REQ-NET-017) put the peer on the same segment */
	nx_ip_gateway_address_set(&ip, (a & 0xFFFFFF00UL) | 1u);
	up = 1;
	return 0;
}

NX_IP *blob_net_ip(void) {
	return &ip;
}

NX_PACKET_POOL *blob_net_pool(void) {
	return &pool;
}

ULONG blob_net_addr(void) {
	return ip_addr;
}

/* the PHY is read through the driver's NX_LINK_GET_STATUS, under the IP instance's mutex: the
 * MDIO transaction is several register steps, and the IP thread and every service thread poll it */
static ULONG link_now(void) {
	ULONG on = NX_FALSE;
	nx_ip_driver_direct_command(&ip, NX_LINK_GET_STATUS, &on);
	return on;
}

void blob_net_wait_link(void) {
	ULONG bits;
	while (nx_ip_status_check(&ip, NX_IP_LINK_ENABLED, &bits, 2 * NX_IP_PERIODIC_RATE) != NX_SUCCESS) {
	}
	while (!link_now()) {
		tx_thread_sleep(NX_IP_PERIODIC_RATE / 10);
	}
	net_link_up = 1;
}

void blob_net_poll_link(void) {
	net_link_up = link_now();
}
