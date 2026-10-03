/* boards/common/shell_glue.c — the CAN shell's built-in TARGET commands, `ps` and `bmc`.
 *
 * loom2v declares shell_ps and shell_bmc on every image with a [shell] (tools/loom2v
 * gen_shell.v) and lists this file in gen/loom_build.mk (LOOM_GLUE_SRCS) whenever it does, so a
 * node gets them by turning the shell on — they are the platform's, not the example's. A node's
 * OWN commands ([shell] commands = [...]) live in its target_ext.c. Three byte-identical
 * copies of these lived in the example glue files until #359.
 *
 * Built with the board's TRACE_CPU_MHZ (boards/<board>/board.mk), the DWT tick rate.
 */
#include "tx_api.h"
#include <stm32h7xx.h> /* CMSIS: DWT */

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
