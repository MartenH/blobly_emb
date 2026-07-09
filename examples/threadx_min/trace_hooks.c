/* P3c-1 phase 2 — real preemptive thread/ISR trace from ThreadX.
 *
 * Built with TX_ENABLE_EXECUTION_CHANGE_NOTIFY, so the M7 port's context-switch and
 * ISR-entry asm call these four hooks. We turn each real context switch into a blobly
 * 8-byte trace record (the same wire format comm/trace emits) in a static ring, and
 * dump the ring over semihosting for the host to decode — no polled loop, no synthesis:
 * these are the true scheduler boundaries.
 *
 * Record: entity_id(u16 LE = kind<<14 | id) | info | start_us(u24 LE) | cpu_us(u16 LE).
 * kinds: ISR=0, THREAD=1. reasons: preempt=0, block=1, yield=2, exit=3.
 */
#include "tx_api.h"

#define KIND_ISR       0u
#define KIND_THREAD    1u
#define REASON_PREEMPT 0u
#define REASON_BLOCK   1u
#define REASON_YIELD   2u
#define REASON_EXIT    3u

#define RING_CAP 256u /* power of two; overwrites oldest (flight recorder) */
static unsigned char g_ring[RING_CAP][8];
volatile unsigned g_head; /* total records pushed (main.c waits on it) */

static void push_rec(unsigned kind, unsigned id, unsigned char info,
                     unsigned long start_us, unsigned dur_us)
{
    unsigned eid = ((kind & 0x3u) << 14) | (id & 0x3FFFu);
    unsigned char *r = g_ring[g_head & (RING_CAP - 1u)];
    r[0] = (unsigned char)(eid & 0xFF);
    r[1] = (unsigned char)((eid >> 8) & 0xFF);
    r[2] = info;
    r[3] = (unsigned char)(start_us & 0xFF);
    r[4] = (unsigned char)((start_us >> 8) & 0xFF);
    r[5] = (unsigned char)((start_us >> 16) & 0xFF);
    r[6] = (unsigned char)(dur_us & 0xFF);
    r[7] = (unsigned char)((dur_us >> 8) & 0xFF);
    g_head++;
}

/* Microsecond clock: the DWT cycle counter (enabled in tx_initialize_low_level.S) on
 * real M7 (the H735, verified in P3c-0). QEMU doesn't model DWT->CYCCNT (reads 0), so
 * fall back to the 100 Hz SysTick count (10 ms granularity) — enough to show the
 * schedule advancing under sim; the H735 gives true microsecond timing. */
#ifndef TRACE_CPU_MHZ
#define TRACE_CPU_MHZ 25u /* QEMU mps2-an500 core clock */
#endif
static volatile unsigned long g_ticks; /* SysTicks seen (isr_enter), the QEMU timebase */
static unsigned long now_us(void)
{
    unsigned long cyc = *(volatile unsigned long *)0xE0001004u; /* DWT->CYCCNT */
    return cyc ? cyc / TRACE_CPU_MHZ : g_ticks * 10000u;
}

/* Map each tx_thread pointer to a small 1-based id (0 = none/idle), assigned on first
 * sight — the host resolves the id to a name via the manifest (a later phase). */
extern TX_THREAD *_tx_thread_current_ptr;
#define MAX_THREADS 8
static void *g_tid_ptr[MAX_THREADS];
static unsigned g_tid_n;
static unsigned thread_id(void *p)
{
    if (!p)
        return 0;
    for (unsigned i = 0; i < g_tid_n; i++)
        if (g_tid_ptr[i] == p)
            return i + 1u;
    if (g_tid_n < MAX_THREADS) {
        g_tid_ptr[g_tid_n] = p;
        return ++g_tid_n;
    }
    return 0;
}

/* ThreadX tx_thread_state -> blobly yield reason (why the outgoing thread stopped). */
static unsigned char state_reason(unsigned st)
{
    switch (st) {
    case 0:  return REASON_PREEMPT; /* TX_READY: preempted, still runnable */
    case 4:  return REASON_YIELD;   /* TX_SLEEP */
    case 1:                          /* TX_COMPLETED */
    case 2:  return REASON_EXIT;    /* TX_TERMINATED */
    default: return REASON_BLOCK;   /* suspended on a resource */
    }
}

/* Carried across a switch: the outgoing thread + when it started running + its reason. */
static void *g_prev_ptr;
static unsigned long g_prev_start;
static unsigned char g_prev_reason = REASON_PREEMPT;
static unsigned long g_isr_start;

void _tx_execution_initialize(void) {}

/* thread_exit runs while current_ptr is still the OUTGOING thread — capture its fate. */
void _tx_execution_thread_exit(void)
{
    g_prev_reason = _tx_thread_current_ptr
                        ? state_reason((unsigned)_tx_thread_current_ptr->tx_thread_state)
                        : REASON_BLOCK;
}

/* thread_enter runs after the switch: emit a THREAD record for the thread that just
 * ran [g_prev_start, now], then arm the incoming thread's start. */
void _tx_execution_thread_enter(void)
{
    unsigned long t = now_us();
    unsigned pid = thread_id(g_prev_ptr);
    if (pid != 0) {
        unsigned long dur = t - g_prev_start;
        push_rec(KIND_THREAD, pid, g_prev_reason, g_prev_start,
                 (unsigned)(dur > 0xFFFFu ? 0xFFFFu : dur));
    }
    g_prev_ptr = _tx_thread_current_ptr;
    g_prev_start = t;
}

void _tx_execution_isr_enter(void)
{
    g_ticks++; /* SysTick is the periodic ISR here -> the QEMU fallback timebase */
    g_isr_start = now_us();
}

void _tx_execution_isr_exit(void)
{
    unsigned long dur = now_us() - g_isr_start;
    push_rec(KIND_ISR, 0u /* SysTick vector */, 0u, g_isr_start,
             (unsigned)(dur > 0xFFFFu ? 0xFFFFu : dur));
}

/* ---- semihosting dump: TRACE_DUMP, one hex record per line, TRACE_END ---- */
static long sh(long op, void *arg)
{
    register long r0 __asm__("r0") = op;
    register void *r1 __asm__("r1") = arg;
    __asm__ volatile("bkpt 0xAB" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}
static void sh_writec(unsigned char c) { char b = (char)c; sh(0x03, &b); }
static void hexb(unsigned char b)
{
    static const char *h = "0123456789abcdef";
    sh_writec((unsigned char)h[b >> 4]);
    sh_writec((unsigned char)h[b & 0xF]);
}
void trace_dump(void)
{
    unsigned total = g_head;
    unsigned n = total > RING_CAP ? RING_CAP : total;
    unsigned start = total > RING_CAP ? total - RING_CAP : 0;
    sh(0x04, (void *)"TRACE_DUMP\n"); /* SYS_WRITE0 */
    for (unsigned i = 0; i < n; i++) {
        unsigned char *r = g_ring[(start + i) & (RING_CAP - 1u)];
        for (int j = 0; j < 8; j++)
            hexb(r[j]);
        sh_writec('\n');
    }
    sh(0x04, (void *)"TRACE_END\n");
}
