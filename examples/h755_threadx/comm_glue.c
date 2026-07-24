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
#include "board.h" /* board_now_us for the cm4 rate window */
#include "duo.h"  /* the dual-core shared-SRAM map (heartbeat, clocks-ready, IOC pool) */

/* Cross-thread signal IOC pool (wait-free triple-buffer, ioc.h). GENERIC target glue: a small
 * indexed pool the generator assigns cells out of, so a bus->app rx signal decoded by the comm
 * thread reaches an FB on the app thread without a lock (the blobly IOC invariant), and V — which
 * can't express the atomics/volatile — calls these scalar wrappers by cell index. loom2v wires
 * which index carries which signal; this file stays config-independent. (A generated per-MCU/
 * target C backend could emit this later; per docs/architecture.md it's fine as target glue now.) */
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
/* ioc_get_ever — glue-contract completeness (the io_glue.c ever-published gate): 1 once
 * the cell has EVER been published, latched race-free IN the consuming exchange
 * (ioc_read_ever); seen[] is sticky and reader-private (one reader per cell). */
int ioc_get_ever(int i, unsigned *a, unsigned *b) {
    static unsigned char seen[IOC_POOL_N];
    if (i < 0 || i >= IOC_POOL_N) { *a = 0; *b = 0; return 0; }
    int ever = 0;
    sig_t v = ioc_read_ever(&g_ioc_pool[i], &ever);
    if (ever) seen[i] = 1;
    *a = v.a; *b = v.b;
    return seen[i];
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

/* duo_clocks_ready — the boot handshake's CM7 half: written once after board_clock_init,
 * releasing the parked CM4 (its SysTick assumes the final 200 MHz HCLK).
 *
 * The wide window is zeroed FIRST: the comm thread may poll a wide channel before the
 * satellite's boot has run duo_xw_init, and an uninitialized SRAM `words` field would
 * otherwise be trusted as a copy bound (codex #211). Zeroed, every pre-init poll reads
 * latest == 0 -> "nothing published" — and xioc_n_read additionally clamps the bound.
 * Config-independent: the whole DUO_XW_MAX window, not the generated layout. */
void duo_clocks_ready(void) {
    volatile uint32_t *xw = (volatile uint32_t *)DUO_XW_ADDR;
    for (uint32_t i = 0; i < DUO_XW_MAX / 4u; i++) xw[i] = 0u;
    __asm__ volatile("dsb");
    *(volatile uint32_t *)DUO_CLK_ADDR = DUO_CLK_MAGIC;
    __asm__ volatile("dsb");
}

#include "xioc.h"
#include "duo_gen.h" /* generated: the cross-core slot contract (gen/duo_gen.h) */
#define DUO_POOL ((xioc_t *)DUO_IOC_ADDR)

/* duo_poll_n — the wide-channel (xioc_n) reader: rd_seq/dst are the CALLER's per-signal
 * state (the generated comm loop declares one seq + lane buffer per wide signal), so this
 * stays stateless — any number of wide channels, no static table to size. `words` is the
 * READER's build-time lane count: a channel whose shared geometry disagrees (a stale
 * satellite image after a partial reflash) reads as never-fresh instead of overrunning
 * the lane buffer (codex #211 r2). 1 = dst now holds a newer complete value; on 0 dst
 * is untouched (last-good retention). */
int duo_poll_n(uint32_t off, uint32_t words, uint32_t *rd_seq, uint32_t *dst) {
	return xioc_n_read((xioc_n_t *)(DUO_XW_ADDR + off), rd_seq, dst, words);
}

/* dtrace: the M7 half of the two-core trace handoff (duo.h). Single writer per field:
 * we own req_seq/op, the satellite owns ack_seq/count and the snapshot buffer.
 *
 * The exchange doubles as the cross-core clock measurement (REQ-TRACE-011). Both cores
 * timestamp their records from their own free-running origin — we boot first and release the
 * CM4 later, so at any instant our clock reads MORE than its — and a dump of both is
 * uncomparable until that difference is known. We bracket the round trip (t1 = request
 * released, t3 = ack observed) around the satellite's own stamp (t2, written just before it
 * acks) and solve it the way any round-trip clock sync does: t2 sits somewhere in [t1, t3], so
 * the midpoint is the best estimate and half the round trip bounds the error. Re-measured on
 * every snapshot, so a CM4 that reset cannot be drawn against a stale offset. */
unsigned long trace_now_us(void);

static uint32_t g_trc_t1;    /* our clock when we released the request */
static uint32_t g_trc_t3;    /* our clock when we first observed the ack */
static int g_trc_have_t3;    /* a round trip completed since the last request */

void duo_trace_req(uint32_t op) {
    volatile uint32_t *c = (volatile uint32_t *)DUO_TRC_ADDR;
    c[1] = op;
    g_trc_have_t3 = 0; /* this request's round trip has not closed yet */
    /* Sample as late as possible before releasing: time spent here is time the bound must
     * cover. */
    g_trc_t1 = (uint32_t)trace_now_us();
    __asm__ volatile("dmb" ::: "memory");
    c[0] = c[0] + 1u; /* req_seq++ releases the request */
}

int duo_trace_ready(void) {
    volatile uint32_t *c = (volatile uint32_t *)DUO_TRC_ADDR;
    if (c[2] != c[0])
        return 0; /* ack has not caught up */
    /* Stamp t3 on the polling pass that FIRST sees the ack — a later pass would charge our own
     * poll interval to the satellite and inflate the bound. */
    if (!g_trc_have_t3) {
        g_trc_t3 = (uint32_t)trace_now_us();
        g_trc_have_t3 = 1;
    }
    return 1;
}

/* duo_trace_offset — the satellite's clock minus ours, in µs, from the round trip that just
 * closed; *bound_us is half that round trip, the residual uncertainty the host should show
 * rather than round away. Returns 0 when no exchange has completed, so the caller emits no
 * correlation at all instead of claiming a 0 skew it never measured.
 *
 * All three stamps come from one clock each, so the u32 subtractions are modular and stay
 * correct across the ~71-minute wrap as long as the true offset fits in an int32 (~35 min) —
 * far beyond any plausible core-release delay. */
int duo_trace_offset(int32_t *off_us, uint32_t *bound_us) {
    volatile uint32_t *c = (volatile uint32_t *)DUO_TRC_ADDR;
    if (!g_trc_have_t3)
        return 0;
    uint32_t rtt = g_trc_t3 - g_trc_t1;
    uint32_t mid = g_trc_t1 + rtt / 2u; /* our clock at the satellite's best-estimate stamp */
    uint32_t raw = c[DUO_TRC_SVC_IDX] - mid; /* modular u32 difference */
    /* The u32 us clocks wrap every ~71.6 min, so a satellite restart can alias ANY
     * modular difference back into range — a wide guard band still admits e.g. a 60-min
     * restart aliasing to +11.6 min (codex #207, round 2). Accept only offsets inside the
     * PLAUSIBLE release-skew window (bench measured ~50 ms; 60 s is generous), which
     * shrinks the alias exposure to restarts landing within +/-60 s of a 71.6-min
     * multiple. The residual alias is unfixable with 32-bit stamps — a 64-bit svc stamp
     * is the real close-out, noted in the bench queue. Out-of-window = refuse: the host
     * shows "not measured" rather than a confident lie. */
    if (raw > 60000000u && raw < 0xFFFFFFFFu - 60000000u) { /* |offset| > 60 s */
        return 0;
    }
    *off_us = (int32_t)raw;
    *bound_us = rtt / 2u;
    return 1;
}

uint32_t duo_trace_count(void) {
    volatile uint32_t *c = (volatile uint32_t *)DUO_TRC_ADDR;
    uint32_t n = c[3];
    return n > DUO_TRC_MAX_REC ? DUO_TRC_MAX_REC : n;
}

unsigned char *duo_trace_buf(void) {
    return (unsigned char *)DUO_TRC_BUF_ADDR;
}

/* duo_poll — the generated comm loop's reader: 1 if slot i has a value newer than the
 * last poll (out params always hold the best-known value). Reader state per slot lives
 * here (comm thread only). */
int duo_poll(int i, uint32_t *a, uint32_t *b) {
    static xioc_rd_t rd[DUO_IOC_N];
    if (i < 0 || i >= DUO_IOC_N) return 0;
    int fresh = xioc_read(&DUO_POOL[i], &rd[i]);
    *a = rd[i].a;
    *b = rd[i].b;
    return fresh;
}

/* shell_m4sig — the `m4sig` command: the M4 FB's signal off cross-core IOC slot 0.
 * ioc_read is the reader half of the same triple buffer the M4 writes: wait-free,
 * latest-complete-value. n advances 100/s while the M4's 10 ms handler runs. */
int shell_m4sig(unsigned char *out, int cap) {
    char *p = (char *)out, *end = (char *)out + cap;
    static xioc_rd_t rd; /* reader state is reader-private (comm thread only) */
    xioc_read(&DUO_POOL[DUO_SLOT_M4_COUNT], &rd);
    p = ps_str(p, end, "M4 FB: n ");
    p = ps_u32(p, end, rd.a);
    p = ps_str(p, end, "  acc ");
    p = ps_u32(p, end, rd.b);
    p = ps_str(p, end, "\n");
    return (int)(p - (char *)out);
}

/* shell_iocx — the `iocx` command: cross-core xioc HEALTH CHECK against the M4Stress
 * signal (the M4Churn FB publishes {k, k*K} at 500 Hz). A bounded burst of reads checks
 * the channel's two invariants across the core boundary: no torn value (b == a*K
 * exactly) and no time travel (a never decreases). The max-rate tear harness that
 * condemned cross-core LDREX/STREX lived here before the emitter (emb#110). */
int shell_iocx(unsigned char *out, int cap) {
    char *p = (char *)out, *end = (char *)out + cap;
    uint32_t reads = 200000u, tears = 0u, regress = 0u, advances = 0u;
    uint32_t prev = 0u;
    xioc_rd_t rd = {0u, 0u, 0u};
    for (uint32_t i = 0; i < reads; i++) {
        xioc_read(&DUO_POOL[DUO_SLOT_M4_STRESS], &rd); /* slot from duo_gen.h */
        if (rd.seq != 0u && rd.b != rd.a * DUO_STRESS_K) tears++;
        if (rd.a < prev) regress++;
        if (rd.a > prev) advances++;
        prev = rd.a;
    }
    p = ps_str(p, end, "iocx: ");
    p = ps_u32(p, end, reads);
    p = ps_str(p, end, " reads  tears ");
    p = ps_u32(p, end, tears);
    p = ps_str(p, end, "  regressions ");
    p = ps_u32(p, end, regress);
    p = ps_str(p, end, "  fresh advances ");
    p = ps_u32(p, end, advances);
    p = ps_str(p, end, "\n");
    return (int)(p - (char *)out);
}

#include "bootmap.h" /* the boot manager <-> app contract (docs/bootloader.md) */

/* shell_boot — the `boot` command: write the SRAM4 request cell and reset into
 * the boot manager (the app->boot rung, REQ-BOOT-003). The response never
 * leaves the board — the reset preempts the ISO-TP exchange, 0x11-style: NO
 * reply to `boot` IS the ack; the tester's next move is a UDS session to the
 * boot ids. SRAM4 (D3) is already clocked — the duo pool lives there. */
int shell_boot(unsigned char *out, int cap) {
    (void)out;
    (void)cap;
    volatile uint32_t *cell = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
    cell[1] = 1u; /* arg first: the magic makes the pair valid, so it lands last */
    cell[0] = BOOTCELL_REQ_MAGIC;
    __asm__ volatile("dsb");
    NVIC_SystemReset();
    return 0; /* unreachable */
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
#define LOAD_SLOTS 5  /* FB threads (ecumodel caps at 4) + the platform io thread */
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

/* --- [nvm] persistence storage map (docs/nvm.md) ---------------------------------
 * The journal's sector pair = the BANK-2 TAIL (sectors 6+7, carved OUT of the
 * CM4 link regions in cm4_*.ld). Placement honesty (docs/nvm.md "where it
 * lives"): bank-2 programs/erases never stall THIS core (M7 executes from
 * bank 1 — true read-while-write), but the M4 executes from the bank-2 HEAD,
 * and an intra-bank erase stalls its fetches for the erase duration. The
 * design accepts that because ERASES ONLY RUN IN THE NM QUIET WINDOW (the
 * append path never erases — v2 engine rule; the generated flush runs
 * erase_pending at the sleep edges, when the node is quiescing). The M4 is
 * NOT NM-aware: its handlers WILL overrun during that erase (seconds of
 * stalled fetches) — accepted for the demo load on a node entering sleep.
 * A real M4 workload that must run through sleep windows takes the
 * documented out: copy its ~30 KB image to RAM at boot (docs/nvm.md), or
 * park it via a duo-cell handshake before the erase. Record APPENDS (32 B programs,
 * ~us) stall the M4 negligibly. DRY-CODED; the bench validates flash.c for
 * boot + NvM in one pass. Driver: boards/h755zi/flash.c (shared with the
 * bootloader — one driver, two customers). */
uint32_t nvm_map_a(void) { return 0x081C0000u; } /* bank 2, sector 6 */
uint32_t nvm_map_b(void) { return 0x081E0000u; } /* bank 2, sector 7 */
uint32_t nvm_map_size(void) { return 0x00020000u; } /* 128 KB each */
