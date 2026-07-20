/* h755_io target glue: the cross-thread signal IOC pool (boards/common/ioc.h) + the
 * comm-thread board glue.
 *
 * GENERIC target glue, config-independent (the comm_glue.c pattern): a small indexed
 * pool the generator assigns cells out of, so io signals cross between the platform io
 * thread and the FB thread without a lock (the blobly IOC invariant). V can't express
 * the atomics/volatile, so it calls these scalar wrappers by cell index; loom2v wires
 * which index carries which signal.
 *
 * The PotLevel bus signal makes loom2v emit the bus-owning comm thread, so this file
 * also carries its board glue (the examples/h755_threadx comm_glue.c ISR/semaphore/load
 * scratch, minus shell/trace/duo — none are configured here): the FDCAN1 Rx-FIFO0 ISR
 * posts a semaphore the comm thread blocks on, and the FB thread publishes its load
 * through volatile scalars for the CpuLoad producer.
 */
#include "tx_api.h"
#include <stm32h7xx.h>
#include "ioc.h"

#define IOC_POOL_N 4
static ioc_t g_ioc_pool[IOC_POOL_N];
/* size-proportional arenas: 3 x the scalar sig_t per channel, line-rounded +
 * line-aligned so channels never share a cache line (ioc.h invariant) */
static volatile uint8_t g_ioc_arena[IOC_POOL_N][IOC_ARENA_BYTES(sizeof(sig_t))]
    __attribute__((aligned(32)));
void ioc_pool_init(void) {
    for (int i = 0; i < IOC_POOL_N; i++) ioc_init(&g_ioc_pool[i], g_ioc_arena[i], sizeof(sig_t));
}
void ioc_pub(int i, unsigned a, unsigned b) {
    sig_t v = { a, b };
    if (i >= 0 && i < IOC_POOL_N) ioc_write(&g_ioc_pool[i], v);
}
/* One ioc_read per logical read (it advances the reader's private slot), returning both fields. */
void ioc_get(int i, unsigned *a, unsigned *b) {
    sig_t v = { 0, 0 };
    if (i >= 0 && i < IOC_POOL_N) v = ioc_read(&g_ioc_pool[i]);
    *a = v.a; *b = v.b;
}
/* ioc_get_ever — the ever-published gate (docs/io.md, REQ-IO-009): returns 1 once the
 * cell has EVER been published, latched race-free by ioc_read_ever from the same
 * atomic exchange that consumes the fresh flag; *a/*b always hold the latest value. Until then the io thread keeps the driver-
 * established init on an output pin, and an FB handler keeps an input port's declared
 * default (a zero slot is not a sample). seen[] is per-cell and each cell has exactly
 * ONE reader (io thread: outputs; FB thread: inputs) — disjoint bytes, no race. */
int ioc_get_ever(int i, unsigned *a, unsigned *b) {
    static unsigned char seen[IOC_POOL_N];
    if (i < 0 || i >= IOC_POOL_N) { *a = 0; *b = 0; return 0; }
    int ever = 0;
    sig_t v = ioc_read_ever(&g_ioc_pool[i], &ever); /* latched IN the consuming
        exchange — a pre-read check could eat a one-sample pulse (emb#150) */
    if (ever) seen[i] = 1;
    *a = v.a; *b = v.b;
    return seen[i];
}

/* Load scratch: each publishing thread owns ONE slot (single writer) — the FB thread
 * slot 0 (via the load_pub alias), the io thread slot 1 (its manifest position) — and
 * the comm thread reads the SUMS for CpuLoad (single reader), so the io serve time is
 * accounted like an FB pass. VOLATILE — different ThreadX threads, and a plain global
 * could be cached by the -Os compiler so the comm thread keeps sending a stale value.
 * Single-writer-per-slot scalars need no lock (the comm_glue.c slotted pattern). */
#define LOAD_SLOTS 5  /* FB threads (ecumodel caps at 4) + the platform io thread */
static volatile unsigned short g_ld_pm[LOAD_SLOTS], g_ld_100[LOAD_SLOTS],
                               g_ld_1s[LOAD_SLOTS], g_ld_10s[LOAD_SLOTS];
static volatile unsigned g_ld_ovr[LOAD_SLOTS];
/* io-thread execution counter (REQ-IO-014 / emb#150): the io thread ADDS each serve's
 * µs here (single writer); the FB thread reads it before/after its pass and SUBTRACTS the
 * delta, so its wall bracket does not double-count the higher-priority io preemption. A
 * volatile u32 — one aligned 32-bit load is atomic on M7, and io-exec-per-window (< 1 tick)
 * never wraps within a diff. */
static volatile unsigned g_io_exec_us;
void io_exec_add(unsigned us) { g_io_exec_us += us; }
unsigned io_exec_us(void) { return g_io_exec_us; }

void load_pub_slot(int i, unsigned pm, unsigned p100, unsigned p1s, unsigned p10s, unsigned ovr) {
    if (i < 0 || i >= LOAD_SLOTS) return;
    g_ld_pm[i] = (unsigned short)pm; g_ld_100[i] = (unsigned short)p100;
    g_ld_1s[i] = (unsigned short)p1s; g_ld_10s[i] = (unsigned short)p10s; g_ld_ovr[i] = ovr;
}
/* single-thread compatibility: the historical API writes slot 0. */
void load_pub(unsigned pm, unsigned p100, unsigned p1s, unsigned p10s, unsigned ovr) {
    load_pub_slot(0, pm, p100, p1s, p10s, ovr);
}
static unsigned sum16(volatile unsigned short *a) {
    unsigned s = 0;
    for (int i = 0; i < LOAD_SLOTS; i++) s += a[i];
    return s > 1000u ? 1000u : s; /* clamp: the threads share one core */
}
unsigned load_sum_permille(void) { return sum16(g_ld_pm); }
unsigned load_sum_100ms(void)    { return sum16(g_ld_100); }
unsigned load_sum_1s(void)       { return sum16(g_ld_1s); }
unsigned load_sum_10s(void)      { return sum16(g_ld_10s); }
unsigned load_sum_overruns(void) {
    unsigned s = 0;
    for (int i = 0; i < LOAD_SLOTS; i++) s += g_ld_ovr[i];
    return s;
}

/* Comm-thread wake semaphore: the Rx ISR posts it; comm_rx_wait (called from the
 * generated comm thread) blocks on it, so the thread wakes on rx instead of polling. */
static TX_SEMAPHORE g_comm_sem;

/* FDCAN1 Rx-FIFO0 new-message ISR (vectors.S references it unconditionally — never
 * weak-aliased, see the note there). Deliberately tiny: clear the flag, wake the comm
 * thread — no decode, no recv off ISR context (the can_port.h pattern). No exec-change
 * trace brackets: this image builds without TX_ENABLE_EXECUTION_CHANGE_NOTIFY. */
void FDCAN1_IT0_IRQHandler(void) {
    FDCAN1->IR = FDCAN_IR_RF0N;    /* acknowledge the new-message interrupt (write-1-clear) */
    tx_semaphore_put(&g_comm_sem); /* wake comm; rescheduling is deferred to PendSV on exit */
}

/* Create the wake semaphore and enable the FDCAN1 Rx-FIFO0 new-message interrupt on
 * line 0, routed to the NVIC at SysTick's priority (so it never nests with SysTick).
 * The generated comm thread calls this once, after it opens the channel. */
void comm_rx_irq_enable(void) {
    tx_semaphore_create(&g_comm_sem, "comm_sem", 0);
    FDCAN1->IE  |= FDCAN_IE_RF0NE;         /* Rx FIFO0 new message -> interrupt */
    FDCAN1->ILE |= FDCAN_ILE_EINT0;        /* route the group to interrupt line 0 */
    NVIC_SetPriority(FDCAN1_IT0_IRQn, 4u); /* 4<<4 = 0x40 == SysTick: no nesting */
    NVIC_EnableIRQ(FDCAN1_IT0_IRQn);
}

/* Block up to `ticks` ThreadX ticks for the Rx ISR to post, or wake early when it does.
 * Returns the tx_semaphore_get status (0 = woken by rx); the caller then drains the FIFO. */
unsigned comm_rx_wait(unsigned ticks) {
    return (unsigned)tx_semaphore_get(&g_comm_sem, (ULONG)ticks);
}
