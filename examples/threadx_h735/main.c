/* P3c-1 Phase 4a — ThreadX exec-hook trace on the STM32H735, dumped over FDCAN.
 *
 * Phase 3 proved the four TX execution-change hooks (trace_hooks.c) turn every real
 * context switch and ISR into a blobly 8-byte trace record, timestamped from DWT
 * (real µs at 550 MHz). Phase 4a makes the board run STANDALONE — no debugger: the
 * frozen ring is streamed over FDCAN1 (raw per-record frames on the trace record id)
 * instead of semihosting (which the user rightly keeps for emergencies only, never a
 * data path). The host decodes the stream with candump + decode_trace.py.
 *
 * Workload (A/B/C/dumper + ThreadX's system timer thread + SysTick ISR) is the Phase-3
 * demo still; Phase 4b turns the dumper into a real FDCAN-Rx-ISR-driven comm thread and
 * Phase 5 morphs the workers into the h735_app FBs (Governor/Load/Heartbeat).
 */
#include "tx_api.h"
#include "board.h"
#include "can_port.h"

extern volatile unsigned g_head;                    /* records pushed so far (trace_hooks.c) */
void trace_dump_can(int h, unsigned long rec_id);   /* trace_hooks.c: ring -> raw CAN frames */

/* Trace record id — the [trace].record_id of examples/h735_app (blobly_net's manifest). */
#define TRACE_RECORD_ID 0x7E5u

static TX_THREAD t_a, t_b, t_c, t_dump;
static UCHAR s_a[1024], s_b[1024], s_c[1024], s_dump[1024];
static int g_can = -1; /* FDCAN1 handle (bus index "0") */

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
    /* Re-stream the frozen flight recorder every ~1 s so a host candump started at any
     * time catches a full snapshot. The ring is frozen (g_capturing=0) on the first dump,
     * so every pass sends the same records. Phase 6 replaces this with the TraceCmd/ISO-TP
     * handshake blobly_net drives. */
    while (1) {
        if (g_can >= 0)
            trace_dump_can(g_can, TRACE_RECORD_ID);
        tx_thread_sleep(100);
    }
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
    /* Raise the M7 to 550 MHz on PLL1 BEFORE the kernel starts: tx_initialize_low_level
     * (inside tx_kernel_enter) programs the SysTick reload for a 550 MHz core, and the
     * trace-hook timestamps divide DWT cycles by 550. If PLL bring-up falls back to HSI
     * the tick/timestamps skew, but P3c-0 verified the lock on this board. */
    board_clock_init();
    /* FDCAN1 kernel clock (HSE 25 MHz) + PH13/PH14 AF9, then open bus index "0" (classic
     * 500 kbit; the Makefile's BLOB_FDCAN_* set the bit timing). */
    board_can_clock_pins_init();
    g_can = blob_can_open("0", 0);
    tx_kernel_enter(); /* never returns */
    return 0;
}
