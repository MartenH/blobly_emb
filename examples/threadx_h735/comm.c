/* P3c-1 Phase 4b — FDCAN Rx ISR + comm thread on the STM32H735.
 *
 * The architecture (docs/architecture.md, platform-scheduling memory): rx is
 * interrupt-driven. The FDCAN1 Rx-FIFO0 "new message" interrupt wakes a dedicated
 * comm thread, which drains the frames (blob_can_recv — the driver stays polled and
 * non-blocking, REQ-CAN-DRV-003), decodes them into an IOC cell (REQ-COM-001), and
 * does the periodic tx (REQ-COM-004). Application code never runs in ISR context — the
 * ISR only clears the flag and posts a semaphore (exactly the pattern can_port.h
 * documents). Both the comm thread and the Rx ISR are TRACED by the exec-change hooks
 * (the comm thread by name; the ISR as vector id 35 = 16 + FDCAN1_IT0_IRQn 19).
 *
 * Requirements-agnostic to the mechanism: REQ-CAN-DRV-002 (receive without loss) and
 * REQ-COM-001/004 don't mandate ISR-vs-poll — this is the target's implementation of
 * them. The IOC cell here is a plain shared struct; Phase 5 upgrades it to a wait-free
 * triple-buffer IOC in shared SRAM, and Phase 6 has loom2v generate all of it.
 */
#include "tx_api.h"
#include "can_port.h"
#include "ioc.h"
#include <stm32h7xx.h>

extern ioc_t g_workload; /* Load -> comm : {a = iters_seen, b = acc} (fbs.c) */

/* The exec-change trace hooks (trace_hooks.c). A C ISR isn't wrapped by the port's
 * __tx_IntHandler, so we bracket the handler with these ourselves to get it traced —
 * the same calls the asm SysTick handler makes. Single-level only: the Rx IRQ shares
 * SysTick's priority (0x40) so the two never nest (trace_hooks is single-level). */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);

extern int g_can; /* FDCAN1 handle (main.c opened bus index "0") */

/* Comm-thread wake semaphore: the Rx ISR posts it, the comm thread waits on it. */
static TX_SEMAPHORE g_comm_sem;

/* No Tx lock. The system is lock-free by SINGLE-OWNER-PER-CORE: THIS comm thread is the
 * sole caller of blob_can_send for its core's bus(es) — the periodic tx and the trace-ring
 * stream both run here, on one thread, so they can never race the non-reentrant driver, and
 * no mutex is needed. FB threads never touch CAN; they publish signals lock-free via the
 * triple-buffer IOC and the comm thread reads them. */
/* trace_hooks.c is a driver-independent recorder — trace_snapshot() copies the ring into
 * our buffer under a brief freeze, then re-arms; WE (the bus owner) stream that stable copy
 * over CAN, interleaved with rx-drain. Streaming from a copy means the recorder is live
 * throughout the stream (no lost capture window) and records can't be torn by new pushes. */
extern unsigned trace_snapshot(unsigned char out[][8], unsigned max);
#define TRACE_RECORD_ID 0x7E5u
#define TRACE_RING 256u /* == trace_hooks RING_CAP */
#define TRACE_CHUNK 16u /* records streamed per comm-thread iteration (bounds the rx gap) */
static unsigned char g_trace_snap[TRACE_RING][8]; /* stable copy the owner streams from */

/* IOC cell: last received frame + a receive counter, written by the comm thread and
 * read by any consumer thread (Phase 5 makes this a real triple-buffer). volatile so a
 * reader on another thread sees fresh values without a lock (single writer). */
struct comm_rx {
    volatile unsigned long last_id;
    volatile unsigned char last[8];
    volatile unsigned long count;
};
struct comm_rx g_comm_rx;

#define COMM_TX_ID 0x7E1u /* periodic liveness frame (h735_app's LoadDetail id) */

/* FDCAN1 Rx-FIFO0 new-message ISR. Clears the flag, wakes the comm thread. Kept tiny:
 * no decode, no recv — those run on the thread, off ISR context. */
void FDCAN1_IT0_IRQHandler(void)
{
    _tx_execution_isr_enter();      /* trace: ISR vector id from IPSR (= 35) */
    FDCAN1->IR = FDCAN_IR_RF0N;     /* acknowledge the new-message interrupt (write-1-clear) */
    tx_semaphore_put(&g_comm_sem);  /* wake comm; rescheduling is deferred to PendSV on exit */
    _tx_execution_isr_exit();
}

/* Enable the FDCAN1 Rx-FIFO0 new-message interrupt on line 0 and route it to the NVIC
 * at SysTick's priority (so it never preempts/ nests with SysTick). Call after open(). */
void comm_rx_irq_enable(void)
{
    tx_semaphore_create(&g_comm_sem, "comm_sem", 0);
    FDCAN1->IE  |= FDCAN_IE_RF0NE;   /* Rx FIFO0 new message -> interrupt */
    FDCAN1->ILE |= FDCAN_ILE_EINT0;  /* route the group to interrupt line 0 */
    NVIC_SetPriority(FDCAN1_IT0_IRQn, 4u); /* 4<<4 = 0x40 == SysTick: no nesting */
    NVIC_EnableIRQ(FDCAN1_IT0_IRQn);
}

/* The comm thread — the sole owner of this core's bus (single-writer => lock-free). It
 * drains rx into the IOC cell, does the periodic (~100 ms) tx, and streams the trace ring
 * (~1 s). All CAN tx happens HERE, on one thread, so nothing races. Waits on the semaphore
 * with a 100 ms cap so it still runs its timers when the bus is quiet. */
void comm_thread(ULONG unused)
{
    (void)unused;
    ULONG last_tx = tx_time_get();
    ULONG last_trace = tx_time_get();
    unsigned tr_pos = 0, tr_n = 0;
    int tr_active = 0; /* mid-stream of a trace snapshot */
    for (;;) {
        tx_semaphore_get(&g_comm_sem, 10); /* wake on rx, or every ~100 ms for the timers */

        /* Drain every queued frame (blob_can_recv returns 0 per frame, -1 when empty) —
         * so a burst that posted the semaphore once is fully consumed (no loss). */
        uint32_t id;
        unsigned char data[8], len;
        /* `flags` (bit0 = FD, bit1 = extended id) was added to the driver shim and this caller
         * was never updated — the example has not compiled since. It is read and ignored here on
         * purpose: this demo echoes classic 11-bit frames, and the fields below hold 8 bytes and
         * an 11-bit id, so accepting an FD or extended frame would truncate it silently. */
        int rx_flags = 0;
        while (blob_can_recv(g_can, &id, data, &len, &rx_flags) == 0) {
            if (rx_flags != 0)
                continue; /* not classic 11-bit: skip rather than mis-report it */
            g_comm_rx.last_id = id;
            for (int i = 0; i < 8; i++)
                g_comm_rx.last[i] = (i < len) ? data[i] : 0u;
            g_comm_rx.count++;
        }

        ULONG now = tx_time_get();

        /* Periodic tx ~100 ms: publish the Workload signal that flowed Governor -> LoadCmd
         * IOC -> Load -> Workload IOC -> here, so the whole cross-thread FB chain is
         * observable on the bus. bytes 0-3 = iters, bytes 4-7 = acc. Direct blob_can_send
         * (single owner) — dropped, not blocked, if the Tx FIFO is momentarily full. */
        if ((now - last_tx) >= 10u) {
            sig_t w = ioc_read(&g_workload);
            unsigned char p[8] = {
                (unsigned char)w.a, (unsigned char)(w.a >> 8),
                (unsigned char)(w.a >> 16), (unsigned char)(w.a >> 24),
                (unsigned char)w.b, (unsigned char)(w.b >> 8),
                (unsigned char)(w.b >> 16), (unsigned char)(w.b >> 24)
            };
            if (blob_can_tx_ready(g_can))
                blob_can_send(g_can, COMM_TX_ID, p, 8, 0);
            last_tx = now;
        }

        /* Stream the trace ring ~1 s, INCREMENTALLY. Folding the old dumper thread into the
         * bus owner made the tx path single-writer => lock-free (no Tx mutex), but a
         * synchronous 256-record dump would stop this (highest-prio) thread from draining rx
         * for its whole duration -> FIFO overflow. So stream only TRACE_CHUNK records per
         * iteration and let the loop come back around (draining rx + re-checking the sem)
         * between chunks. Records go only while the Tx FIFO has room — no wait/spin — so a
         * stuck bus (no-ACK/bus-off) can never wedge the owner; the stream just doesn't
         * finish (fine, nothing's listening on a dead bus). */
        if (!tr_active && (now - last_trace) >= 100u) {
            /* Copy the ring NOW (brief freeze inside trace_snapshot), then stream the stable
             * copy across the next iterations — the recorder runs live meanwhile. */
            tr_n = trace_snapshot(g_trace_snap, TRACE_RING);
            tr_pos = 0;
            tr_active = 1;
        }
        if (tr_active) {
            unsigned sent = 0;
            while (tr_pos < tr_n && sent < TRACE_CHUNK && blob_can_tx_ready(g_can)) {
                blob_can_send(g_can, TRACE_RECORD_ID, g_trace_snap[tr_pos], 8, 0);
                tr_pos++;
                sent++;
            }
            if (tr_pos >= tr_n) {
                tr_active = 0;
                last_trace = tx_time_get(); /* measure the next gap from stream-END */
            }
        }
    }
}
