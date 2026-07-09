/* P3c-1 Phase 2 — real preemptive thread/ISR trace from ThreadX on Cortex-M7.
 *
 * Workload: two equal-priority workers (A, B) that sleep at different periods, plus a
 * higher-priority preemptor (C) that periodically wakes and PREEMPTS them, plus
 * ThreadX's hidden System Timer Thread and the SysTick ISR. The four TX
 * execution-change hooks (trace_hooks.c) turn every real context switch and ISR into a
 * blobly 8-byte trace record. A dumper thread waits for the ring to fill, then dumps it
 * over semihosting (TRACE_DUMP ... TRACE_END) for the host to decode. Runs under QEMU
 * mps2-an500; the H735 is the next phase.
 */
#include "tx_api.h"

void trace_dump(void);            /* trace_hooks.c */
extern volatile unsigned g_head;  /* records pushed so far (trace_hooks.c) */

static long sh(long op, void *arg)
{
    register long r0 __asm__("r0") = op;
    register void *r1 __asm__("r1") = arg;
    __asm__ volatile("bkpt 0xAB" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}
static void sh_puts(const char *s) { sh(0x04, (void *)s); }

static TX_THREAD t_a, t_b, t_c, t_dump;
static UCHAR s_a[1024], s_b[1024], s_c[1024], s_dump[1024];

static void worker(ULONG which)
{
    while (1)
        tx_thread_sleep(which ? 3 : 2); /* B every 3 ticks, A every 2 -> interleave */
}

static void preemptor(ULONG unused)
{
    (void)unused;
    while (1) {
        for (volatile int i = 0; i < 20000; i++) {} /* burn CPU so it's seen holding the core */
        tx_thread_sleep(5);
    }
}

static void dumper(ULONG unused)
{
    (void)unused;
    while (g_head < 120u) /* let the scheduler run + the ring fill */
        tx_thread_sleep(5);
    sh_puts("threadx trace: dumping\n");
    trace_dump();
    while (1)
        tx_thread_sleep(100);
}

void tx_application_define(void *first_unused_memory)
{
    (void)first_unused_memory;
    tx_thread_create(&t_a, "A", worker, 0, s_a, sizeof(s_a), 5, 5, 1, TX_AUTO_START);
    tx_thread_create(&t_b, "B", worker, 1, s_b, sizeof(s_b), 5, 5, 1, TX_AUTO_START);
    tx_thread_create(&t_c, "C", preemptor, 0, s_c, sizeof(s_c), 3, 3, 1, TX_AUTO_START);
    tx_thread_create(&t_dump, "D", dumper, 0, s_dump, sizeof(s_dump), 2, 2, 1, TX_AUTO_START);
}

int main(void)
{
    sh_puts("threadx_min: M7 ThreadX up\n");
    tx_kernel_enter(); /* never returns */
    return 0;
}
