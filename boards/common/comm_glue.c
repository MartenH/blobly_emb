/* boards/common/comm_glue.c — the GENERIC single-bus ThreadX comm-thread glue.
 *
 * The generated comm thread (loom2v: comm_thread_entry) owns the bus and does all the CAN
 * work in freestanding V. This is the small, board-independent C it cannot express: the
 * cross-thread signal IOC pool, the FDCAN1 Rx-FIFO0 interrupt + the semaphore that wakes
 * the comm thread, and the Loom-load scratch the telemetry module reports.
 *
 * It is config-independent by construction — h735_threadx/comm_glue.c long carried this
 * exact core with a note that "a generated per-MCU/target C backend could emit this later";
 * the system_full multi-node example made a SHARED copy worth extracting so every leaf
 * node (zone_a/zone_b on H723, domain on H755 CM7) links ONE file instead of copy-pasting.
 * A node that also needs a shell, the bootloader hand-off, or the dual-core dtrace handoff
 * adds those in its OWN glue and links this alongside — this file owns only the generic
 * single-bus comm path.
 *
 * FDCAN1 is the physical instance every single-bus node uses (sysgen maps a leaf's one
 * bus to can0 = FDCAN1). The ISR is deliberately tiny — clear the flag, post the
 * semaphore — so decode never runs in interrupt context; it is bracketed by the
 * exec-change trace hooks so a trace shows it as vector id 35 (= 16 + FDCAN1_IT0_IRQn 19).
 */
#include "tx_api.h"
#include <stm32h7xx.h> /* CMSIS family dispatcher (build sets -DSTM32H72x/H75x); no HAL */
#include "ioc.h"

/* ---- cross-thread signal IOC pool (wait-free triple buffer, ioc.h) ---------------------
 * A small indexed pool loom2v assigns cells out of, so a bus->app rx signal decoded by the
 * comm thread reaches an FB on the app thread without a lock (the blobly IOC invariant).
 * 8 cells covers the widest system_full leaf (domain: 8). Raise with -DIOC_POOL_N if a node
 * needs more; the generator's highest cell index must stay below it. */
#ifndef IOC_POOL_N
#define IOC_POOL_N 8
#endif
static ioc_t g_ioc_pool[IOC_POOL_N];
/* size-proportional arenas: 3 x the scalar sig_t per channel, line-rounded + line-aligned
 * so channels never share a cache line (ioc.h invariant). */
static volatile uint8_t g_ioc_arena[IOC_POOL_N][IOC_ARENA_BYTES(sizeof(sig_t))]
    __attribute__((aligned(32)));
void ioc_pool_init(void) {
    for (int i = 0; i < IOC_POOL_N; i++) ioc_init(&g_ioc_pool[i], g_ioc_arena[i], sizeof(sig_t));
}
void ioc_pub(int i, unsigned a, unsigned b) {
    sig_t v = { a, b };
    if (i >= 0 && i < IOC_POOL_N) ioc_write(&g_ioc_pool[i], v);
}
/* one ioc_read per logical read (advances the reader's private slot), both fields out. */
void ioc_get(int i, unsigned *a, unsigned *b) {
    sig_t v = { 0, 0 };
    if (i >= 0 && i < IOC_POOL_N) v = ioc_read(&g_ioc_pool[i]);
    *a = v.a; *b = v.b;
}
/* ioc_get_ever — the glue-contract completeness gate: 1 once the cell has EVER been
 * published, latched race-free IN the consuming exchange (ioc_read_ever); seen[] is sticky
 * and reader-private (one reader per cell). */
int ioc_get_ever(int i, unsigned *a, unsigned *b) {
    static unsigned char seen[IOC_POOL_N];
    if (i < 0 || i >= IOC_POOL_N) { *a = 0; *b = 0; return 0; }
    int ever = 0;
    sig_t v = ioc_read_ever(&g_ioc_pool[i], &ever);
    if (ever) seen[i] = 1;
    *a = v.a; *b = v.b;
    return seen[i];
}

/* ---- Loom-load scratch (telemetry) -----------------------------------------------------
 * The FB thread publishes the Loom load here (single writer, load_pub); the comm thread
 * reads it for the CpuLoad/LoadDetail telemetry frames (single reader). VOLATILE — the two
 * run on different ThreadX threads and -Os could cache a plain global. Single-writer/
 * single-reader scalars need no lock; volatile is enough. */
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

/* ---- FDCAN1 Rx-FIFO0 ISR + comm-thread wake semaphore ---------------------------------- */
static TX_SEMAPHORE g_comm_sem;

/* A C ISR isn't wrapped by the port's asm __tx_IntHandler; bracket it with the exec-change
 * hooks (trace_hooks.c) so it is traced — the same calls the asm SysTick handler makes.
 * Single-level: the Rx IRQ shares SysTick's priority (0x40) so the two never nest. */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);

/* FDCAN1 Rx-FIFO0 new-message ISR. Clears the flag, wakes the comm thread. No decode. */
void FDCAN1_IT0_IRQHandler(void)
{
    _tx_execution_isr_enter();
    FDCAN1->IR = FDCAN_IR_RF0N;     /* acknowledge the new-message interrupt (write-1-clear) */
    tx_semaphore_put(&g_comm_sem);  /* wake comm; reschedule deferred to PendSV on exit */
    _tx_execution_isr_exit();
}

/* Create the wake semaphore and enable the FDCAN1 Rx-FIFO0 new-message interrupt on line 0,
 * at SysTick's priority (no nesting). The generated comm thread calls this once, after it
 * opens the channel. */
void comm_rx_irq_enable(void)
{
    tx_semaphore_create(&g_comm_sem, "comm_sem", 0);
    FDCAN1->IE  |= FDCAN_IE_RF0NE;          /* Rx FIFO0 new message -> interrupt */
    FDCAN1->ILE |= FDCAN_ILE_EINT0;         /* route the group to interrupt line 0 */
    NVIC_SetPriority(FDCAN1_IT0_IRQn, 4u);  /* 4<<4 = 0x40 == SysTick: no nesting */
    NVIC_EnableIRQ(FDCAN1_IT0_IRQn);
}

/* Block up to `ticks` ThreadX ticks for the Rx ISR to post, or wake early when it does.
 * Returns the tx_semaphore_get status (0 = woken by rx); the caller drains the FIFO. */
unsigned comm_rx_wait(unsigned ticks)
{
    return (unsigned)tx_semaphore_get(&g_comm_sem, (ULONG)ticks);
}
