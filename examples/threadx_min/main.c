/* Minimal ThreadX Cortex-M7 bring-up — P3c-1 Phase 1 foundation.
 *
 * Two application threads (A, B) at different sleep periods, plus ThreadX's hidden
 * System Timer Thread, scheduled preemptively on a real M7 kernel. Runs under QEMU
 * mps2-an500; each thread prints its name over semihosting every ~100 iterations so
 * you can see the kernel actually interleaving them. This proves the vendored ThreadX
 * (third_party/threadx, pinned) builds + schedules on M7 before we wire the
 * execution-change trace hooks (Phase 2) and move to the H735.
 */
#include "tx_api.h"

/* ARM semihosting write (works under `qemu -semihosting`). */
static long sh(long op, void *arg)
{
    register long r0 __asm__("r0") = op;
    register void *r1 __asm__("r1") = arg;
    __asm__ volatile("bkpt 0xAB" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}
static void sh_puts(const char *s) { sh(0x04, (void *)s); } /* SYS_WRITE0 */

static TX_THREAD t_a, t_b;
static UCHAR s_a[1024], s_b[1024];
volatile unsigned long a_count, b_count;

static void worker(ULONG which)
{
    while (1) {
        if (which) {
            if ((++b_count % 100) == 0)
                sh_puts("B\n");
        } else {
            if ((++a_count % 100) == 0)
                sh_puts("A\n");
        }
        tx_thread_sleep(which ? 3 : 2); /* different periods so they interleave */
    }
}

void tx_application_define(void *first_unused_memory)
{
    (void)first_unused_memory;
    tx_thread_create(&t_a, "A", worker, 0, s_a, sizeof(s_a), 5, 5, 1, TX_AUTO_START);
    tx_thread_create(&t_b, "B", worker, 1, s_b, sizeof(s_b), 5, 5, 1, TX_AUTO_START);
}

int main(void)
{
    sh_puts("threadx_min: M7 ThreadX up\n");
    tx_kernel_enter(); /* never returns */
    return 0;
}
