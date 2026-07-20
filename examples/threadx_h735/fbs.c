/* P3c-1 Phase 5 — the h735_app function blocks as real ThreadX threads.
 *
 * Governor -> [LoadCmd IOC] -> Load -> [Workload IOC] -> comm (-> CAN telemetry): the
 * same FB set as examples/h735_app, now each on its own preemptive ThreadX thread instead
 * of a superloop, with the cross-thread signals carried by the wait-free triple-buffer IOC
 * (ioc.h) — no locks, no spinning, no torn values. On this single-core H735 the IOC lives
 * in DTCM RAM; the identical code carries the signal across cores from shared SRAM, which
 * is what Phase 6's generated cross-core IOC does.
 *
 * Periods are in 100 Hz ThreadX ticks (10 ms): Load every tick, Governor + Heartbeat every
 * 10. h735_app's ecu.toml calls these 1 ms / 100 ms against a 1 ms superloop; the 10:1
 * ratio (fast Load vs slow Governor) is what the trace shows, and Phase 6 can drive a
 * faster tick from the config.
 */
#include "tx_api.h"
#include "ioc.h"

/* Cross-thread signals. Phase 6 places these in shared SRAM for the cross-core case. */
ioc_t g_loadcmd;  /* Governor -> Load : a = iters */
ioc_t g_workload; /* Load -> comm     : a = iters_seen, b = acc */
/* size-proportional arenas: 3 x the scalar sig_t per channel, line-rounded +
 * line-aligned so the two channels never share a cache line (ioc.h invariant) */
volatile uint8_t g_loadcmd_arena[IOC_ARENA_BYTES(sizeof(sig_t))] __attribute__((aligned(32)));
volatile uint8_t g_workload_arena[IOC_ARENA_BYTES(sizeof(sig_t))] __attribute__((aligned(32)));

/* Governor's triangle-wave work command (mirrors h735_app): the load breathes 48k..96k
 * LCG iterations, one 2k step per run, so Load's CPU time in the trace rises and falls
 * rather than sitting flat — a healthy, non-pegged system. */
#define ITERS_MIN  48000u
#define ITERS_MAX  96000u
#define ITERS_STEP 2000u

void governor_thread(ULONG unused)
{
	(void)unused;
	uint32_t iters = ITERS_MIN;
	int rising = 1;
	for (;;) {
		if (rising) {
			iters += ITERS_STEP;
			if (iters >= ITERS_MAX) {
				iters = ITERS_MAX;
				rising = 0;
			}
		} else {
			iters -= ITERS_STEP;
			if (iters <= ITERS_MIN) {
				iters = ITERS_MIN;
				rising = 1;
			}
		}
		sig_t v = { iters, 0u };
		ioc_write(&g_loadcmd, v);
		tx_thread_sleep(10); /* 100 ms */
	}
}

/* Load: read the commanded iteration count from the LoadCmd IOC, burn that many LCG rounds
 * (real, non-elidable CPU load — acc is published), then publish {iters_seen, acc} so the
 * work flows on to the comm thread's telemetry. */
void load_thread(ULONG unused)
{
	(void)unused;
	uint32_t acc = 1u;
	for (;;) {
		uint32_t iters = ioc_read(&g_loadcmd).a;
		for (uint32_t i = 0; i < iters; i++)
			acc = acc * 1664525u + 1013904223u;
		sig_t v = { iters, acc };
		ioc_write(&g_workload, v);
		tx_thread_sleep(1); /* ~10 ms (h735_app's 1 ms fast loop, at the 100 Hz tick) */
	}
}

/* Heartbeat: a cheap timer-only FB (no signals) — a third named thread at its period, like
 * h735_app's Heartbeat. */
void heartbeat_thread(ULONG unused)
{
	(void)unused;
	for (;;)
		tx_thread_sleep(10); /* 100 ms */
}
