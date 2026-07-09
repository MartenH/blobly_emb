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
#include <stm32h7xx.h>

/* The exec-change trace hooks (trace_hooks.c). A C ISR isn't wrapped by the port's
 * __tx_IntHandler, so we bracket the handler with these ourselves to get it traced —
 * the same calls the asm SysTick handler makes. Single-level only: the Rx IRQ shares
 * SysTick's priority (0x40) so the two never nest (trace_hooks is single-level). */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);

extern int g_can; /* FDCAN1 handle (main.c opened bus index "0") */

/* Comm-thread wake semaphore: the Rx ISR posts it, the comm thread waits on it. */
static TX_SEMAPHORE g_comm_sem;

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

/* The comm thread: rx-driven decode into the IOC cell + periodic (~100 ms) tx. Waits on
 * the semaphore with a 100 ms cap so it also runs when the bus is quiet (for the tx). */
void comm_thread(ULONG unused)
{
    (void)unused;
    ULONG last_tx = tx_time_get();
    for (;;) {
        tx_semaphore_get(&g_comm_sem, 10); /* wake on rx, or every ~100 ms for the tx */

        /* Drain every queued frame (blob_can_recv returns 0 per frame, -1 when empty) —
         * so a burst that posted the semaphore once is fully consumed (no loss). */
        uint32_t id;
        unsigned char data[8], len;
        while (blob_can_recv(g_can, &id, data, &len) == 0) {
            g_comm_rx.last_id = id;
            for (int i = 0; i < 8; i++)
                g_comm_rx.last[i] = (i < len) ? data[i] : 0u;
            g_comm_rx.count++;
        }

        /* Periodic tx ~100 ms: a liveness frame carrying the rx count, paced by the
         * non-blocking tx_ready back-pressure (REQ-CAN-DRV-007) — dropped, not blocked,
         * if the Tx FIFO is momentarily full. */
        ULONG now = tx_time_get();
        if ((now - last_tx) >= 10u && blob_can_tx_ready(g_can)) {
            unsigned long c = g_comm_rx.count;
            unsigned char p[8] = {
                (unsigned char)c, (unsigned char)(c >> 8),
                (unsigned char)(c >> 16), (unsigned char)(c >> 24),
                (unsigned char)g_comm_rx.last_id, (unsigned char)(g_comm_rx.last_id >> 8),
                0u, 0u
            };
            blob_can_send(g_can, COMM_TX_ID, p, 8, 0);
            last_tx = now;
        }
    }
}
