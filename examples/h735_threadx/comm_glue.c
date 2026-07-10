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

/* Comm-thread wake semaphore: the Rx ISR posts it; comm_rx_wait (called from the generated
 * comm thread) blocks on it, so the thread wakes on rx instead of polling. */
static TX_SEMAPHORE g_comm_sem;

/* Load scratch: the FB thread publishes the Loom load here (single writer, load_pub); the comm
 * thread reads it for CpuLoad/LoadDetail (single reader, load_*). VOLATILE — the two run on
 * different ThreadX threads, and a plain global could be cached by the -Os compiler so the comm
 * thread keeps sending a stale value. Single-writer/single-reader scalars need no lock; volatile
 * is enough. The wait-free triple-buffer IOC replaces this when the target IOC layer lands
 * (6b-2b); V can't emit volatile globals, so it lives here as thin target glue for now. */
static volatile unsigned short g_ld_pm, g_ld_100, g_ld_1s, g_ld_10s;
static volatile unsigned g_ld_ovr;
void load_pub(unsigned pm, unsigned p100, unsigned p1s, unsigned p10s, unsigned ovr) {
    g_ld_pm = (unsigned short)pm; g_ld_100 = (unsigned short)p100;
    g_ld_1s = (unsigned short)p1s; g_ld_10s = (unsigned short)p10s; g_ld_ovr = ovr;
}
unsigned load_permille(void) { return g_ld_pm; }
unsigned load_100ms(void)    { return g_ld_100; }
unsigned load_1s(void)       { return g_ld_1s; }
unsigned load_10s(void)      { return g_ld_10s; }
unsigned load_overruns(void) { return g_ld_ovr; }

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
