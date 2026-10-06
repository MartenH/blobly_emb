/* A sampling CPU profiler: TIM7 interrupts ~9973 times a second (not a multiple of the 1 kHz tick,
 * so periodic work cannot alias with it) and records what the core was doing at that instant — a
 * ThreadX thread, an interrupt, or ThreadX's idle wait. Over a second that is ~10 000 samples: the
 * share of each, to about 0.01%, at about 0.1% of the CPU. No kernel options, no trace hooks.
 *
 * Counters only ever grow (one writer, the sampling ISR); a reader differences two cpuprof_read()s. */
#ifndef BOARD_CPUPROF_H
#define BOARD_CPUPROF_H
#include <stdint.h>
#include "tx_api.h"

#define CPUPROF_THREADS 16 /* threads told apart; a later one is counted as "other" */

typedef struct {
	uint32_t total, idle, isr, other;
	uint32_t n;                         /* threads seen so far */
	TX_THREAD *thread[CPUPROF_THREADS];
	uint32_t count[CPUPROF_THREADS];
} cpuprof_t;

/* cpuprof_start: TIM7 at ~9973 Hz, at the highest interrupt priority so it samples inside other
 * interrupts too. Call once. TIM7 must be free (the io PWM map uses TIM1/TIM2). */
void cpuprof_start(void);

/* cpuprof_read: a copy of the counters (each word read whole; a sample landing mid-copy moves one
 * count between the copy's fields, never more) */
void cpuprof_read(cpuprof_t *out);

#endif
