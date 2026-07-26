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

/* ---- FDCAN Rx-FIFO0 ISRs + comm-thread wake semaphore ----------------------------------
 * ONE wake semaphore, shared by every FDCAN instance a node owns: a single-bus leaf arms
 * FDCAN1 only; a multi-bus gateway (system_full sysnode) arms FDCAN1/2/3 and the comm thread
 * drains all of them each wake. The semaphore is a plain count, so N instances posting it
 * just means "at least one FIFO has a frame" — the comm loop then drains every channel.
 * FDCAN3 exists only on 3-FDCAN parts (H72x/H73x, e.g. the H735-DK); it is #ifdef-guarded so
 * this one file still links on H74x/H75x (2 FDCAN). */
static TX_SEMAPHORE g_comm_sem;
static unsigned char g_comm_sem_made; /* create-once: several comm_rx_irq_enable_idx() calls */

/* A C ISR isn't wrapped by the port's asm __tx_IntHandler; bracket it with the exec-change
 * hooks (trace_hooks.c) so it is traced — the same calls the asm SysTick handler makes.
 * Single-level: the Rx IRQ shares SysTick's priority (0x40) so the two never nest. */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);

/* Rx-FIFO0 new-message ISR body: clear THIS instance's flag, wake the comm thread. No decode. */
static inline void comm_rx_isr(FDCAN_GlobalTypeDef *c)
{
    _tx_execution_isr_enter();
    c->IR = FDCAN_IR_RF0N;          /* acknowledge the new-message interrupt (write-1-clear) */
    tx_semaphore_put(&g_comm_sem);  /* wake comm; reschedule deferred to PendSV on exit */
    _tx_execution_isr_exit();
}

void FDCAN1_IT0_IRQHandler(void) { comm_rx_isr(FDCAN1); }
void FDCAN2_IT0_IRQHandler(void) { comm_rx_isr(FDCAN2); }
#ifdef FDCAN3
void FDCAN3_IT0_IRQHandler(void) { comm_rx_isr(FDCAN3); }
#endif

/* Map a bus index (0..2) to its instance + IRQ number. Returns 0 if the part lacks it. */
static FDCAN_GlobalTypeDef *comm_inst(int idx, IRQn_Type *irq)
{
    switch (idx) {
    case 0: *irq = FDCAN1_IT0_IRQn; return FDCAN1;
    case 1: *irq = FDCAN2_IT0_IRQn; return FDCAN2;
#ifdef FDCAN3
    case 2: *irq = FDCAN3_IT0_IRQn; return FDCAN3;
#endif
    default: return 0;
    }
}

/* Enable the Rx-FIFO0 new-message interrupt for FDCAN instance `idx` (0..2) on line 0, at
 * SysTick's priority (no nesting). The wake semaphore is created on the first call. The
 * generated comm thread calls this once per bus it owns, after opening each channel. */
void comm_rx_irq_enable_idx(int idx)
{
    IRQn_Type irq;
    FDCAN_GlobalTypeDef *c = comm_inst(idx, &irq);
    if (!c) return;                         /* instance absent on this part — nothing to arm */
    if (!g_comm_sem_made) {
        tx_semaphore_create(&g_comm_sem, "comm_sem", 0);
        g_comm_sem_made = 1u;
    }
    c->IE  |= FDCAN_IE_RF0NE;               /* Rx FIFO0 new message -> interrupt */
    c->ILE |= FDCAN_ILE_EINT0;              /* route the group to interrupt line 0 */
    NVIC_SetPriority(irq, 4u);              /* 4<<4 = 0x40 == SysTick: no nesting */
    NVIC_EnableIRQ(irq);
}

/* Back-compat single-bus entry: arm FDCAN1 only. Every existing leaf node calls this. */
void comm_rx_irq_enable(void) { comm_rx_irq_enable_idx(0); }

/* Block up to `ticks` ThreadX ticks for the Rx ISR to post, or wake early when it does.
 * Returns the tx_semaphore_get status (0 = woken by rx); the caller drains the FIFO. */
unsigned comm_rx_wait(unsigned ticks)
{
    return (unsigned)tx_semaphore_get(&g_comm_sem, (ULONG)ticks);
}
