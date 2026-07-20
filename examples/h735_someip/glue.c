/* h735_someip board glue (docs/someip.md target rung). The generated
 * gen/loom_gen.v owns everything protocol-shaped (FB thread, eth comm thread,
 * tx_application_define); the NetX transport is the shared driver backend
 * (driver/eth/eth_netx.c). This file is only what neither can express:
 *
 * The byte IOC pool — the struct-bearing twin of the comm_glue.c scalar pool:
 * a small indexed pool of wait-free triple-buffer channels (boards/common/
 * ioc.h) the generator assigns per eth signal, each arena carved out
 * SIZE-PROPORTIONALLY (3 x the signal's struct) at iocb_cfg time, so V —
 * which can't express the atomics/volatile — publishes and acquires whole
 * signal structs by cell index. loom2v wires which index carries which
 * signal; this file stays config-independent. */
#include <stdint.h>
#include "ioc.h"

#define IOCB_POOL_N     8
/* worst case; used = the line-rounded 3 x each signal (IOC_ARENA_BYTES) */
#define IOCB_ARENA_SIZE (IOCB_POOL_N * IOC_ARENA_BYTES(IOC_MAX))
static ioc_t g_iocb[IOCB_POOL_N];
static volatile uint8_t g_iocb_arena[IOCB_ARENA_SIZE] __attribute__((aligned(32)));
static uint32_t g_iocb_used;
static unsigned char g_iocb_seen[IOCB_POOL_N]; /* sticky ever-published, reader-private */

/* iocb_cfg carves channel i's arena (3 x size bytes) and inits the protocol.
 * Called from the generated boot() before any thread runs; a pool overrun is
 * a config bug loud enough to halt boot (never a silent alias). */
void iocb_cfg(int i, unsigned short size) {
	if (i < 0 || i >= IOCB_POOL_N || size == 0u || size > IOC_MAX
	    || g_iocb_used + IOC_ARENA_BYTES(size) > sizeof(g_iocb_arena)) {
		for (;;) {
		}
	}
	ioc_init(&g_iocb[i], &g_iocb_arena[g_iocb_used], size);
	/* line-rounded stride: channels never share a cache line (ioc.h) */
	g_iocb_used += IOC_ARENA_BYTES(size);
}

void iocb_pub(int i, const void *src) {
	if (i >= 0 && i < IOCB_POOL_N) {
		ioc_write_bytes(&g_iocb[i], src);
	}
}

void iocb_get(int i, void *dst) {
	if (i >= 0 && i < IOCB_POOL_N) {
		ioc_read_bytes(&g_iocb[i], dst);
	}
}

/* iocb_get_ever — the io_glue.c ever-published gate, byte-channel form: 1 once
 * the cell has EVER been published, latched race-free IN the consuming
 * exchange (ioc_read_bytes_ever). The eth thread's tx gate: a frame whose
 * signals were never published sends nothing (the host bridge's any_ rule). */
int iocb_get_ever(int i, void *dst) {
	if (i < 0 || i >= IOCB_POOL_N) {
		return 0;
	}
	int ever = 0;
	ioc_read_bytes_ever(&g_iocb[i], dst, &ever);
	if (ever) {
		g_iocb_seen[i] = 1;
	}
	return g_iocb_seen[i];
}

/* shared vector table: this image has no CAN — parked stub. */
void FDCAN1_IT0_IRQHandler(void) {
	for (;;) {
	}
}
