/* P3c-1 Phase 5 — the h735_app function blocks as real ThreadX threads on the STM32H735.
 *
 * Phase 3 proved the exec-hook trace on silicon; 4a dumped it over FDCAN (standalone); 4b
 * added the FDCAN-Rx-ISR-driven comm thread. Phase 5 replaces the A/B/C demo workers with
 * the actual h735_app FB set — Governor, Load, Heartbeat — each on its own preemptive
 * ThreadX thread (fbs.c), with the cross-thread signals carried by a wait-free triple-
 * buffer IOC (ioc.h): Governor -> [LoadCmd] -> Load -> [Workload] -> comm -> CAN. No locks,
 * no spinning, no torn values. The full chain is observable: every thread is traced by name
 * on 0x7E5, and comm's 0x7E1 telemetry carries the Workload signal that flowed through the
 * IOCs, so the host sees Load's result tracking Governor's command.
 *
 * Phase 6 generates all of this — threads, IOC, ISR wiring — from h735_app's ecu.toml. The
 * trace ring still streams over FDCAN1 as raw per-record frames on 0x7E5 (host decodes with
 * candump + decode_trace.py); blobly_net's ISO-TP swimlane lands in Phase 6.
 */
#include "tx_api.h"
#include "board.h"
#include "can_port.h"

#include "ioc.h"

extern volatile unsigned g_head;                    /* records pushed so far (trace_hooks.c) */
void trace_dump_can(int h, unsigned long rec_id);   /* trace_hooks.c: ring -> raw CAN frames */
void comm_thread(ULONG unused);                     /* comm.c: FDCAN-Rx-ISR-driven comm thread */
void comm_rx_irq_enable(void);                      /* comm.c: enable + route the Rx FIFO0 IRQ */
void governor_thread(ULONG unused);                 /* fbs.c: 100 ms, writes LoadCmd */
void load_thread(ULONG unused);                     /* fbs.c: reads LoadCmd, writes Workload */
void heartbeat_thread(ULONG unused);                /* fbs.c: 100 ms, timer-only */
extern ioc_t g_loadcmd, g_workload;                 /* fbs.c: the cross-thread signal IOCs */

/* Trace record id — the [trace].record_id of examples/h735_app (blobly_net's manifest). */
#define TRACE_RECORD_ID 0x7E5u

static TX_THREAD t_gov, t_load, t_hb, t_dump, t_comm;
static UCHAR s_gov[1024], s_load[1024], s_hb[1024], s_dump[1024], s_comm[1024];
int g_can = -1; /* FDCAN1 handle (bus index "0"); comm.c shares it */

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
    /* The cross-thread signal IOCs must be initialised before any FB thread runs. */
    ioc_init(&g_loadcmd);
    ioc_init(&g_workload);

    /* The h735_app FBs as ThreadX threads (ThreadX: lower number = higher priority). Load
     * runs fastest so it gets the higher priority (5); Governor/Heartbeat are the slow
     * 100 ms FBs (6, 7). The comm thread stays highest (1) and the dumper at 2. */
    tx_thread_create(&t_load, "Load", load_thread, 0, s_load, sizeof(s_load), 5, 5, 1, TX_AUTO_START);
    tx_thread_create(&t_gov, "Gov", governor_thread, 0, s_gov, sizeof(s_gov), 6, 6, 1, TX_AUTO_START);
    tx_thread_create(&t_hb, "Hb", heartbeat_thread, 0, s_hb, sizeof(s_hb), 7, 7, 1, TX_AUTO_START);
    tx_thread_create(&t_dump, "D", dumper, 0, s_dump, sizeof(s_dump), 2, 2, 1, TX_AUTO_START);
    /* The comm thread — HIGHEST priority (1). The Rx ISR only posts the semaphore and the
     * 8-deep FDCAN FIFO is drained here, so comm must preempt the workload/dump to drain rx
     * before the FIFO overflows — the receive-without-loss path (REQ-CAN-DRV-002). Enable
     * the FDCAN Rx IRQ once its wake semaphore + tx mutex exist. */
    tx_thread_create(&t_comm, "comm", comm_thread, 0, s_comm, sizeof(s_comm), 1, 1, 1, TX_AUTO_START);
    comm_rx_irq_enable();
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
