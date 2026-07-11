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
#define KIND_FB        2u
#define REASON_PREEMPT 0u
#define REASON_BLOCK   1u
#define REASON_YIELD   2u
#define REASON_EXIT    3u

#define RING_CAP 256u /* power of two; overwrites oldest (flight recorder) */
static unsigned char g_ring[RING_CAP][8];
volatile unsigned g_head; /* total records pushed (main.c waits on it) */
static volatile int g_capturing = 1; /* trace_dump() clears this to freeze the ring */

static void push_rec(unsigned kind, unsigned id, unsigned char info,
                     unsigned long start_us, unsigned dur_us)
{
    if (!g_capturing)
        return; /* frozen for a dump — don't overwrite records being read out */
    /* The thread-switch (PendSV) path re-enables interrupts before the enter hook, so an
     * ISR push can race a thread push. Serialise slot-claim + write with a brief PRIMASK
     * critical section — records are 8 bytes, so it's tiny. */
    unsigned prim;
    __asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");
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
    __asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");
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
    /* Accumulate 32-bit CYCCNT deltas into a 64-bit tally so the µs value doesn't wrap
     * every ~7.8 s (32 bits at 550 MHz) — the hooks fire far more often than that. A
     * PRIMASK critical section serialises the statics (an ISR can preempt a thread hook
     * mid-read). If DWT reads 0 (QEMU doesn't model CYCCNT) fall back to the SysTick
     * count (10 ms granularity); the H735 gives true µs. */
    static unsigned long last_cyc;
    static unsigned long long acc;
    unsigned prim;
    __asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");
    unsigned long cyc = *(volatile unsigned long *)0xE0001004u; /* DWT->CYCCNT */
    unsigned long r;
    if (cyc == 0u && acc == 0ull) {
        r = g_ticks * 10000u;
    } else {
        acc += (unsigned long long)(unsigned long)(cyc - last_cyc); /* modular 32-bit delta */
        last_cyc = cyc;
        r = (unsigned long)(acc / TRACE_CPU_MHZ);
    }
    __asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");
    return r;
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

static unsigned long g_slice_start;  /* when the currently-running thread started */
static unsigned long g_slice_isr_us; /* ISR time that interrupted the current slice */
static unsigned long g_isr_start;
static unsigned g_isr_vec; /* active exception number of the ISR in progress */

void _tx_execution_initialize(void) {}

/* active exception (ISR) number from IPSR: SysTick = 15, IRQn = 16 + n. */
static unsigned active_vector(void)
{
    unsigned v;
    __asm__ volatile("mrs %0, ipsr" : "=r"(v));
    return v & 0x1FFu;
}

/* thread_exit runs while current_ptr is still the OUTGOING thread — close its slice
 * NOW (at the real stop time), not at the next enter, which idle time could delay. */
void _tx_execution_thread_exit(void)
{
    unsigned long t = now_us();
    unsigned id = thread_id(_tx_thread_current_ptr);
    if (id != 0) {
        /* the thread's CPU is its wall slice minus the ISR time that preempted it */
        unsigned long wall = t - g_slice_start;
        unsigned long dur = wall > g_slice_isr_us ? wall - g_slice_isr_us : 0u;
        unsigned char reason = _tx_thread_current_ptr
                                   ? state_reason((unsigned)_tx_thread_current_ptr->tx_thread_state)
                                   : REASON_BLOCK;
        push_rec(KIND_THREAD, id, reason, g_slice_start,
                 (unsigned)(dur > 0xFFFFu ? 0xFFFFu : dur));
    }
}

/* thread_enter runs after the switch — the incoming thread's slice starts now. */
void _tx_execution_thread_enter(void)
{
    g_slice_start = now_us();
    g_slice_isr_us = 0u; /* fresh slice: no ISR time charged yet */
}

/* ISR enter/exit bracket the active interrupt. Single-level: nested ISRs (a higher
 * priority preempting one already hooked) would need a small vec/start stack — the
 * demo only runs SysTick, so one level suffices for now. */
void _tx_execution_isr_enter(void)
{
    g_isr_vec = active_vector();
    if (g_isr_vec == 15u)
        g_ticks++; /* SysTick -> the QEMU fallback timebase */
    g_isr_start = now_us();
}

void _tx_execution_isr_exit(void)
{
    unsigned long dur = now_us() - g_isr_start;
    g_slice_isr_us += dur; /* charge this ISR against the interrupted thread's slice */
    push_rec(KIND_ISR, g_isr_vec, 0u, g_isr_start,
             (unsigned)(dur > 0xFFFFu ? 0xFFFFu : dur));
}

/* ---- Trace ring read-out: PURE RECORDER, no CAN driver dependency ----
 * trace_hooks.c only records exec-change events into the ring; it must NOT touch the CAN
 * driver seam (the example-layer invariant: only the generated bridge / thin entry import
 * driver/can). So instead of sending here, we expose a frozen snapshot the bus owner (the
 * comm thread) reads and streams itself — the owner interleaves rx-drain between chunks and
 * owns all back-pressure / liveness decisions.
 *
 * trace_snapshot() copies up to `max` of the most recent records into the owner's buffer
 * under a BRIEF freeze (just the copy), then re-arms — so the recorder is disabled only for
 * the memcpy, not for the whole (incremental, back-pressure-paced) stream that follows. The
 * owner then streams from its stable copy, so records can't be torn by new pushes and no
 * capture window is lost. Each 8-byte record is one classic CAN frame on the host side
 * (candump | decode_trace.py); blobly_net's ISO-TP swimlane is a later concern. */
/* trace_fb(): an FB-handler interval from the app thread's Loom hook. The ring is otherwise
 * written from ISR/scheduler context, so a thread-context push must not be torn by a preempting
 * ISR push — briefly mask interrupts around it (a few dozen cycles, same as board_now_us). */
void trace_fb(unsigned id, unsigned long long start_us, unsigned dur_us)
{
    /* start_us is a 64-bit us timestamp: on AAPCS32 it rides r2:r3 (r1 skipped for alignment)
     * and dur lands on the stack — the prototype must be 64-bit or every arg after id is junk. */
    unsigned pm;
    __asm volatile("mrs %0, primask" : "=r"(pm));
    __asm volatile("cpsid i" ::: "memory");
    push_rec(KIND_FB, id, 0u, (unsigned long)start_us, dur_us > 0xFFFFu ? 0xFFFFu : dur_us);
    __asm volatile("msr primask, %0" :: "r"(pm) : "memory");
}

/* trace_arm(): start a fresh capture window — clear the ring under a brief freeze and resume
 * recording. The command path (TraceCmd arm/start/reset routed to the trace module) calls this
 * so "arm" means "from now", not "the last RING_CAP records of forever". */
void trace_arm(void)
{
    g_capturing = 0;
    g_head = 0;
    g_capturing = 1;
}

unsigned trace_snapshot(unsigned char out[][8], unsigned max)
{
    g_capturing = 0; /* freeze only for the copy below */
    unsigned total = g_head;
    unsigned n = total > RING_CAP ? RING_CAP : total;
    if (n > max)
        n = max;
    /* Copy the LATEST n records (start = total - n), not the oldest of the ring window — so
     * a caller passing max < RING_CAP (e.g. buffer_records=64) gets the most recent 64. */
    unsigned start = total - n;
    for (unsigned i = 0; i < n; i++)
        for (int j = 0; j < 8; j++)
            out[i][j] = g_ring[(start + i) & (RING_CAP - 1u)][j];
    g_capturing = 1; /* re-arm immediately — recording resumes for the whole stream */
    return n;
}
