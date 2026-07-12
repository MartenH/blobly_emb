/* h735_threadx comm-thread board glue (P3c-1 phase 6b-2).
 *
 * The GENERATED comm thread (gen/loom_gen.v: comm_thread_entry) owns the bus and does all
 * the CAN work in V. This file is the small, board-specific glue it can't express in
 * freestanding V: the FDCAN1 Rx-FIFO0 interrupt + the semaphore that wakes the comm thread.
 * It mirrors the hand-written examples/threadx_h735/comm.c ISR/enable, minus the thread body
 * (which loom2v now emits). Reused board bring-up, like board.c / trace_hooks.c.
 *
 * The ISR is deliberately tiny — clear the flag, post the semaphore — so application/decode
 * code never runs in interrupt context (the can_port.h pattern). It's bracketed by the
 * exec-change hooks so the trace shows it as vector id 35 (= 16 + FDCAN1_IT0_IRQn 19).
 */
#include "tx_api.h"
#include <stm32h7xx.h>
#include "ioc.h"

/* Cross-thread signal IOC pool (wait-free triple-buffer, ioc.h). GENERIC target glue: a small
 * indexed pool the generator assigns cells out of, so a bus->app rx signal decoded by the comm
 * thread reaches an FB on the app thread without a lock (the blobly IOC invariant), and V — which
 * can't express the atomics/volatile — calls these scalar wrappers by cell index. loom2v wires
 * which index carries which signal; this file stays config-independent. (A generated per-MCU/
 * target C backend could emit this later; per docs/architecture.md it's fine as target glue now.) */
#define IOC_POOL_N 4
static ioc_t g_ioc_pool[IOC_POOL_N];
void ioc_pool_init(void) {
    for (int i = 0; i < IOC_POOL_N; i++) ioc_init(&g_ioc_pool[i]);
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

/* shell_ps: the `ps` command — walk ThreadX's created-thread list and format one line per
 * thread: name, priority, state, stack used/size (high-water = first untouched byte from the
 * stack's low end; stacks live in zeroed BSS, so scanning for the first non-zero byte is a
 * faithful watermark without TX_ENABLE_STACK_CHECKING). Read-only kernel globals — safe from
 * the comm thread (com-modules interaction rule 1). Bounded: <=16 threads, one pass each. */
extern TX_THREAD *_tx_thread_created_ptr;
extern ULONG _tx_thread_created_count;

static char *ps_str(char *p, char *end, const char *s) {
    while (*s && p < end) *p++ = *s++;
    return p;
}
static char *ps_u32(char *p, char *end, unsigned v) {
    char d[10]; int n = 0;
    if (!v) { if (p < end) *p++ = '0'; return p; }
    while (v) { d[n++] = (char)('0' + v % 10u); v /= 10u; }
    while (n && p < end) *p++ = d[--n];
    return p;
}
static const char *ps_state(unsigned st) {
    switch (st) {
    case 0:  return "ready";
    case 1:  return "done";
    case 2:  return "dead";
    case 3:  return "susp";
    case 4:  return "sleep";
    case 6:  return "sem";
    case 13: return "mutex";
    default: return "wait";
    }
}
/* shell_bmc — the `bmc` shell command: a BOUNDED micro-benchmark over the DWT profiling
 * counters. The counters (CPICNT/EXCCNT/SLEEPCNT/LSUCNT/FOLDCNT) are 8 BITS wide; their
 * DWT_CTRL.*EVTENA enables make them count, and on wrap they emit an event -- but only
 * into the ITM trace stream, which this board has no sink for. So free-running system-wide
 * totals are impossible here; instead bmc runs a known register-only LCG loop (the same
 * arithmetic the load FBs burn) in chunks small enough that NO counter can advance 256
 * between samples, accumulating exact 64-bit totals. IRQs stay live (~0.5 ms on the comm
 * thread), so exc/sleep show real interference during the window.
 *
 * v7-M profiling identity: instructions retired
 *     = CYCCNT - CPICNT - EXCCNT - SLEEPCNT - LSUCNT + FOLDCNT.
 */
#define BMC_CHUNKS 1024
#define BMC_ITERS  64 /* per chunk: ~5 instr each, every 8-bit delta stays < 256 */
int shell_bmc(unsigned char *out, int cap) {
    char *p = (char *)out, *end = (char *)out + cap;
    if (DWT->CTRL & DWT_CTRL_NOPRFCNT_Msk)
        return (int)(ps_str(p, end, "no DWT profiling counters on this core\n") - (char *)out);
    DWT->CTRL |= DWT_CTRL_CPIEVTENA_Msk | DWT_CTRL_EXCEVTENA_Msk | DWT_CTRL_SLEEPEVTENA_Msk
               | DWT_CTRL_LSUEVTENA_Msk | DWT_CTRL_FOLDEVTENA_Msk;
    uint32_t cpi = 0, exc = 0, slp = 0, lsu = 0, fold = 0;
    uint32_t acc = 1u;
    uint32_t c0 = DWT->CYCCNT;
    for (int chunk = 0; chunk < BMC_CHUNKS; chunk++) {
        uint8_t cpi0 = (uint8_t)DWT->CPICNT, exc0 = (uint8_t)DWT->EXCCNT;
        uint8_t slp0 = (uint8_t)DWT->SLEEPCNT, lsu0 = (uint8_t)DWT->LSUCNT;
        uint8_t fold0 = (uint8_t)DWT->FOLDCNT;
        for (int i = 0; i < BMC_ITERS; i++) acc = acc * 1664525u + 1013904223u;
        __asm__ volatile("" : : "r"(acc)); /* consume acc so the loop survives -Os */
        cpi  += (uint8_t)((uint8_t)DWT->CPICNT   - cpi0);
        exc  += (uint8_t)((uint8_t)DWT->EXCCNT   - exc0);
        slp  += (uint8_t)((uint8_t)DWT->SLEEPCNT - slp0);
        lsu  += (uint8_t)((uint8_t)DWT->LSUCNT   - lsu0);
        fold += (uint8_t)((uint8_t)DWT->FOLDCNT  - fold0);
    }
    uint32_t cycles = DWT->CYCCNT - c0;
    uint32_t insn = cycles - cpi - exc - slp - lsu + fold; /* the identity above */
    uint32_t us = cycles / TRACE_CPU_MHZ; /* build define; DWT ticks at the CPU clock */
    p = ps_str(p, end, "64k-iter LCG window on comm, IRQs live\n");
    p = ps_str(p, end, "cycles "); p = ps_u32(p, end, cycles);
    p = ps_str(p, end, " ("); p = ps_u32(p, end, us); p = ps_str(p, end, " us)\n");
    p = ps_str(p, end, "instr  "); p = ps_u32(p, end, insn);
    p = ps_str(p, end, "  CPIx100 "); p = ps_u32(p, end, insn ? (uint32_t)((uint64_t)cycles * 100u / insn) : 0u);
    p = ps_str(p, end, "\n");
    p = ps_str(p, end, "cpi+   "); p = ps_u32(p, end, cpi);
    p = ps_str(p, end, "  (multi-cycle/fetch-stall extras)\n");
    p = ps_str(p, end, "lsu+   "); p = ps_u32(p, end, lsu);
    p = ps_str(p, end, "  (load/store extras)\n");
    p = ps_str(p, end, "fold   "); p = ps_u32(p, end, fold);
    p = ps_str(p, end, "  (0-cycle instructions)\n");
    p = ps_str(p, end, "exc    "); p = ps_u32(p, end, exc);
    p = ps_str(p, end, "  (exception entry/exit cycles)\n");
    p = ps_str(p, end, "sleep  "); p = ps_u32(p, end, slp); p = ps_str(p, end, "\n");
    return (int)(p - (char *)out);
}

int shell_ps(unsigned char *out, int cap) {
    char *p = (char *)out, *end = (char *)out + cap;
    p = ps_str(p, end, "name                pri state stack\n");
    TX_THREAD *t = _tx_thread_created_ptr;
    for (ULONG i = 0; i < _tx_thread_created_count && t && i < 16u; i++, t = t->tx_thread_created_next) {
        const char *nm = t->tx_thread_name ? t->tx_thread_name : "?";
        char *col = p + 20;
        for (int c = 0; nm[c] && c < 19 && p < end; c++) *p++ = nm[c];
        while (p < col && p < end) *p++ = ' ';
        /* pri and state are space-padded to fixed columns (like the name) — natural width
         * ('0' vs '11', 'susp' vs 'ready') would make every column after them wobble */
        col = p + 4;
        p = ps_u32(p, end, (unsigned)t->tx_thread_priority);
        while (p < col && p < end) *p++ = ' ';
        col = p + 6;
        p = ps_str(p, end, ps_state((unsigned)t->tx_thread_state));
        while (p < col && p < end) *p++ = ' ';
        /* high-water: first non-zero byte from the stack's LOW end (stacks grow down) */
        unsigned char *lo = (unsigned char *)t->tx_thread_stack_start;
        unsigned char *hi = (unsigned char *)t->tx_thread_stack_end;
        unsigned size = (unsigned)(hi - lo) + 1u;
        /* ThreadX memsets the whole stack to TX_STACK_FILL (0xEF) at create (default build,
         * TX_DISABLE_STACK_FILLING off) — the high-water mark is the first byte the thread
         * overwrote, scanning up from the stack's low end. */
        unsigned untouched = 0;
        while (lo + untouched <= hi && lo[untouched] == 0xEFu) untouched++;
        p = ps_u32(p, end, size - untouched);
        p = ps_str(p, end, "/");
        p = ps_u32(p, end, size);
        p = ps_str(p, end, "\n");
    }
    return (int)(p - (char *)out);
}

/* Comm-thread wake semaphore: the Rx ISR posts it; comm_rx_wait (called from the generated
 * comm thread) blocks on it, so the thread wakes on rx instead of polling. */
static TX_SEMAPHORE g_comm_sem;

/* Load scratch: the FB thread publishes the Loom load here (single writer, load_pub); the comm
 * thread reads it for CpuLoad/LoadDetail (single reader, load_*). VOLATILE — the two run on
 * different ThreadX threads, and a plain global could be cached by the -Os compiler so the comm
 * thread keeps sending a stale value. Single-writer/single-reader scalars need no lock; volatile
 * is enough. The wait-free triple-buffer IOC replaces this when the target IOC layer lands
 * (6b-2b); V can't emit volatile globals, so it lives here as thin target glue for now. */
#define LOAD_SLOTS 4  /* one per FB thread (ecumodel caps threads at 4) */
static volatile unsigned short g_ld_pm[LOAD_SLOTS], g_ld_100[LOAD_SLOTS],
                               g_ld_1s[LOAD_SLOTS], g_ld_10s[LOAD_SLOTS];
static volatile unsigned g_ld_ovr[LOAD_SLOTS];
/* per-thread publisher: each FB thread owns ONE slot (single writer), comm sums them. */
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

/* The exec-change trace hooks (trace_hooks.c). A C ISR isn't wrapped by the port's asm
 * __tx_IntHandler, so we bracket the handler with these to get it traced — the same calls the
 * asm SysTick handler makes. Single-level: the Rx IRQ shares SysTick's priority (0x40) so the
 * two never nest (trace_hooks is single-level). */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);

/* FDCAN1 Rx-FIFO0 new-message ISR. Clears the flag, wakes the comm thread. No decode, no
 * recv — those run on the thread, off ISR context. */
void FDCAN1_IT0_IRQHandler(void)
{
    _tx_execution_isr_enter();      /* trace: ISR vector id from IPSR (= 35) */
    FDCAN1->IR = FDCAN_IR_RF0N;     /* acknowledge the new-message interrupt (write-1-clear) */
    tx_semaphore_put(&g_comm_sem);  /* wake comm; rescheduling is deferred to PendSV on exit */
    _tx_execution_isr_exit();
}

/* Create the wake semaphore and enable the FDCAN1 Rx-FIFO0 new-message interrupt on line 0,
 * routed to the NVIC at SysTick's priority (so it never nests with SysTick). The generated
 * comm thread calls this once, after it opens the channel. */
void comm_rx_irq_enable(void)
{
    tx_semaphore_create(&g_comm_sem, "comm_sem", 0);
    FDCAN1->IE  |= FDCAN_IE_RF0NE;          /* Rx FIFO0 new message -> interrupt */
    FDCAN1->ILE |= FDCAN_ILE_EINT0;         /* route the group to interrupt line 0 */
    NVIC_SetPriority(FDCAN1_IT0_IRQn, 4u);  /* 4<<4 = 0x40 == SysTick: no nesting */
    NVIC_EnableIRQ(FDCAN1_IT0_IRQn);
}

/* Block up to `ticks` ThreadX ticks for the Rx ISR to post, or wake early when it does.
 * Returns the tx_semaphore_get status (0 = woken by rx); the caller then drains the FIFO. */
unsigned comm_rx_wait(unsigned ticks)
{
    return (unsigned)tx_semaphore_get(&g_comm_sem, (ULONG)ticks);
}
