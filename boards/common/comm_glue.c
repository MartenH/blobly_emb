/* boards/common/comm_glue.c — the ONE generic ThreadX glue every generated image links.
 *
 * The generated threads (loom2v: the FB thread(s), comm_thread_entry, the io thread) do their
 * work in freestanding V. This is the small, board-independent C they cannot express: the
 * cross-thread signal IOC pool, the per-thread Loom-load cells the CpuLoad telemetry sums, the
 * io thread's execution counter, and the FDCAN Rx-FIFO0 interrupts + the semaphore that wakes
 * the comm thread.
 *
 * It covers every shape loom2v generates — one app thread or several, one FDCAN or a gateway's
 * three, io points or none — so an image never chooses between glue files: which images link it
 * is a fact loom2v writes into gen/loom_build.mk (LOOM_GLUE_SRCS), and loom2v's comm_glue_syms
 * lists what it may declare from here (pinned by tools/loom2v/threadx_makefiles_test.v). It was
 * two files once, comm_glue.c (multi-bus, one load cell) and io_glue.c (load slots, FDCAN1 only),
 * and a multi-thread gateway could link neither (#359).
 *
 * A node that also needs a shell command, the bootloader hand-off, the dual-core handoff or an
 * extra wake source adds those in its OWN file and links this alongside — it never redefines a
 * symbol here. An extra wake source arms itself in comm_wake_sources_arm (weak no-op in
 * weak_irq.c) and posts through comm_wake.
 */
#include "tx_api.h"
#include <stm32h7xx.h> /* CMSIS family dispatcher (build sets -DSTM32H72x/H75x); no HAL */
#include "ioc.h"

/* ---- cross-thread signal IOC pool (wait-free triple buffer, ioc.h) ---------------------
 * A small indexed pool loom2v assigns cells out of, so a signal crosses threads without a
 * lock (the blobly IOC invariant): a bus->app rx signal decoded by the comm thread, persist
 * staging, and the io thread's points. V can't express the atomics/volatile, so it calls these
 * scalar wrappers by cell index; loom2v wires which index carries which signal.
 *
 * MUST equal loom2v's cell ceiling (tools/loom2v ioc_pool_n, which refuses an image needing
 * more): a smaller pool silently drops any generated index >= IOC_POOL_N in ioc_pub/get —
 * system_full zone_a's slot 4 (HeadlightLed) sat at its init level that way (codex, #247). */
#define IOC_POOL_N 16
static ioc_t g_ioc_pool[IOC_POOL_N];
/* size-proportional arenas: 3 x the scalar sig_t per channel, line-rounded + line-aligned
 * so channels never share a cache line (ioc.h invariant). */
static volatile uint8_t g_ioc_arena[IOC_POOL_N][IOC_ARENA_BYTES(sizeof(sig_t))]
    __attribute__((aligned(32)));
void ioc_pool_init(void) {
    for (int i = 0; i < IOC_POOL_N; i++) ioc_init(&g_ioc_pool[i], g_ioc_arena[i], sizeof(sig_t));
}
void ioc_pub(int i, unsigned a, unsigned b) {
    sig_t v = { a, b };
    if (i >= 0 && i < IOC_POOL_N) ioc_write(&g_ioc_pool[i], v);
}
/* g_ioc_seen[i]: cell i has EVER been published, latched by whichever read consumed its
 * first fresh flag — ioc_get and ioc_get_ever alike, so a plain read of a cell (a DID refresh on
 * the comm thread) cannot eat the one publish the ever gate is waiting for. Per-cell, written only
 * by the cell's one reader thread (each cell has exactly ONE: io thread for outputs, FB thread for
 * inputs, comm thread for TX signals) — disjoint bytes, no race. */
static unsigned char g_ioc_seen[IOC_POOL_N];
/* One ioc_read per logical read (it advances the reader's private slot), both fields out. */
void ioc_get(int i, unsigned *a, unsigned *b) {
    sig_t v = { 0, 0 };
    int ever = 0;
    if (i >= 0 && i < IOC_POOL_N) {
        v = ioc_read_ever(&g_ioc_pool[i], &ever);
        if (ever) g_ioc_seen[i] = 1;
    }
    *a = v.a; *b = v.b;
}
/* ioc_get_ever — the ever-published gate (docs/io.md, REQ-IO-009; REQ-COM-011): returns 1 once
 * the cell has EVER been published, latched race-free by ioc_read_ever from the same atomic
 * exchange that consumes the fresh flag; *a/*b always hold the latest value. Until then the io
 * thread keeps the driver-established init on an output pin, an FB handler keeps an input port's
 * declared default (a zero slot is not a sample), and a comm-thread producer sends its frame's
 * initial payload. */
int ioc_get_ever(int i, unsigned *a, unsigned *b) {
    if (i < 0 || i >= IOC_POOL_N) { *a = 0; *b = 0; return 0; }
    ioc_get(i, a, b); /* latched IN the consuming exchange — a pre-read check could eat a
        one-sample pulse (emb#150) */
    return g_ioc_seen[i];
}

/* ---- Loom-load cells (telemetry) -------------------------------------------------------
 * Each publishing thread owns ONE slot (single writer): a one-thread image's FB thread
 * writes slot 0 through the load_pub alias, a multi-thread image's FB threads write their
 * own slots (load_pub_slot), and the io thread writes its manifest position. The comm thread
 * reads slot 0 (load_*) or the SUMS (load_sum_*, so io's serve time and every FB thread land
 * in CpuLoad) — single reader. VOLATILE — different ThreadX threads, and a plain global could
 * be cached by the -Os compiler so the comm thread keeps sending a stale value.
 * Single-writer-per-slot scalars need no lock. */
#define LOAD_SLOTS 5  /* FB threads (ecumodel caps at 4) + the platform io thread */
static volatile unsigned short g_ld_pm[LOAD_SLOTS], g_ld_100[LOAD_SLOTS],
                               g_ld_1s[LOAD_SLOTS], g_ld_10s[LOAD_SLOTS];
static volatile unsigned g_ld_ovr[LOAD_SLOTS];
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
unsigned load_permille(void) { return g_ld_pm[0]; }
unsigned load_100ms(void)    { return g_ld_100[0]; }
unsigned load_1s(void)       { return g_ld_1s[0]; }
unsigned load_10s(void)      { return g_ld_10s[0]; }
unsigned load_overruns(void) { return g_ld_ovr[0]; }
unsigned load_sum_permille(void) { return sum16(g_ld_pm); }
unsigned load_sum_100ms(void)    { return sum16(g_ld_100); }
unsigned load_sum_1s(void)       { return sum16(g_ld_1s); }
unsigned load_sum_10s(void)      { return sum16(g_ld_10s); }
unsigned load_sum_overruns(void) {
    unsigned s = 0;
    for (int i = 0; i < LOAD_SLOTS; i++) s += g_ld_ovr[i];
    return s;
}

/* io-thread execution counter (REQ-IO-014 / emb#150): the io thread ADDS each serve's
 * µs here (single writer); the FB thread reads it before/after its pass and SUBTRACTS the
 * delta, so its wall bracket does not double-count the higher-priority io preemption. A
 * volatile u32 — one aligned 32-bit load is atomic on M7, and io-exec-per-window (< 1 tick)
 * never wraps within a diff. */
static volatile unsigned g_io_exec_us;
void io_exec_add(unsigned us) { g_io_exec_us += us; }
unsigned io_exec_us(void) { return g_io_exec_us; }

/* ---- FDCAN Rx-FIFO0 ISRs + comm-thread wake semaphore ----------------------------------
 * ONE wake semaphore, shared by every FDCAN instance a node owns: a single-bus leaf arms
 * FDCAN1 only; a multi-bus gateway (system_full sysnode) arms FDCAN1/2 — and FDCAN3 on a 3-FDCAN
 * part, once loom2v can route a third bus (it refuses can2 today: it does not know the part) — and the comm thread
 * drains all of them each wake. The semaphore is a plain count, so N instances posting it
 * just means "at least one FIFO has a frame" — the comm loop then drains every channel.
 * FDCAN3 exists only on 3-FDCAN parts (H72x/H73x, e.g. the H735-DK); it is #ifdef-guarded so
 * this one file still links on H74x/H75x (2 FDCAN). The part's vector table (vectors_h72x.S /
 * vectors_h75x.S) references each handler unconditionally — never weak-aliased, see the note
 * there — and only the H72x table has the IRQ159 slot FDCAN3's needs (#360). */
static TX_SEMAPHORE g_comm_sem;
static unsigned char g_comm_sem_made; /* create-once: several comm_rx_irq_enable_idx() calls */

/* A C ISR isn't wrapped by the port's asm __tx_IntHandler; bracket it with the exec-change
 * hooks (trace_hooks.c) so it is traced — the same calls the asm SysTick handler makes —
 * on an image whose ThreadX records the trace. Single-level: the Rx IRQ shares SysTick's
 * priority (0x40) so the two never nest. Guarded: a trace-less image builds without them. */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);

/* Rx-FIFO0 new-message ISR body: clear THIS instance's flag, wake the comm thread. No decode. */
static inline void comm_rx_isr(FDCAN_GlobalTypeDef *c)
{
#ifdef TX_ENABLE_EXECUTION_CHANGE_NOTIFY
    _tx_execution_isr_enter();      /* trace: ISR vector id from IPSR (FDCAN1 = 35) */
#endif
    c->IR = FDCAN_IR_RF0N;          /* acknowledge the new-message interrupt (write-1-clear) */
    tx_semaphore_put(&g_comm_sem);  /* wake comm; reschedule deferred to PendSV on exit */
#ifdef TX_ENABLE_EXECUTION_CHANGE_NOTIFY
    _tx_execution_isr_exit();
#endif
}

void FDCAN1_IT0_IRQHandler(void) { comm_rx_isr(FDCAN1); }
void FDCAN2_IT0_IRQHandler(void) { comm_rx_isr(FDCAN2); }
#ifdef FDCAN3
void FDCAN3_IT0_IRQHandler(void) { comm_rx_isr(FDCAN3); }
#endif

/* Map a bus index (0..2) to its instance + IRQ number. Returns 0 if the part lacks it. */
static FDCAN_GlobalTypeDef *comm_inst(int idx, IRQn_Type *irq)
{
    switch (idx) {
    case 0: *irq = FDCAN1_IT0_IRQn; return FDCAN1;
    case 1: *irq = FDCAN2_IT0_IRQn; return FDCAN2;
#ifdef FDCAN3
    case 2: *irq = FDCAN3_IT0_IRQn; return FDCAN3;
#endif
    default: return 0;
    }
}

/* A node's other wake sources (the H755 cross-core bulk doorbell): armed ONCE, right after
 * the semaphore exists and the first FDCAN is armed, so their ISR can post it (comm_wake).
 * Weak no-op default in weak_irq.c — a separate object, so the strong one always wins. */
extern void comm_wake_sources_arm(void);

/* Enable the Rx-FIFO0 new-message interrupt for FDCAN instance `idx` (0..2) on line 0, at
 * SysTick's priority (no nesting). The wake semaphore is created on the first call. The
 * generated comm thread calls this once per bus it owns, after opening each channel. */
void comm_rx_irq_enable_idx(int idx)
{
    IRQn_Type irq;
    FDCAN_GlobalTypeDef *c = comm_inst(idx, &irq);
    if (!c) return;                         /* instance absent on this part — nothing to arm */
    unsigned char first = !g_comm_sem_made;
    if (first) {
        tx_semaphore_create(&g_comm_sem, "comm_sem", 0);
        g_comm_sem_made = 1u;
    }
    c->IE  |= FDCAN_IE_RF0NE;               /* Rx FIFO0 new message -> interrupt */
    c->ILE |= FDCAN_ILE_EINT0;              /* route the group to interrupt line 0 */
    NVIC_SetPriority(irq, 4u);              /* 4<<4 = 0x40 == SysTick: no nesting */
    NVIC_EnableIRQ(irq);
    if (first) comm_wake_sources_arm();
}

/* Single-bus entry: arm FDCAN1 only. Every leaf node's comm thread calls this. */
void comm_rx_irq_enable(void) { comm_rx_irq_enable_idx(0); }

/* Block up to `ticks` ThreadX ticks for the Rx ISR to post, or wake early when it does.
 * Returns the tx_semaphore_get status (0 = woken by rx); the caller drains the FIFO. */
unsigned comm_rx_wait(unsigned ticks)
{
    return (unsigned)tx_semaphore_get(&g_comm_sem, (ULONG)ticks);
}

/* Wake the comm thread from another thread or an ISR (driver/eth/doip_netx.c: a DoIP request
 * is waiting; a node's own wake source). Before the semaphore exists the comm thread has not
 * reached its loop: it serves on its first pass. */
void comm_wake(void)
{
    if (g_comm_sem_made)
        tx_semaphore_put(&g_comm_sem);
}
