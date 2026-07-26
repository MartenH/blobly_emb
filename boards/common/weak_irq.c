/* boards/common/weak_irq.c — weak default(s) for FDCAN interrupt vectors that the SHARED
 * vector table (vectors.S) references but only a bus-owning image defines.
 *
 * The shared vectors.S wires IRQ20 to FDCAN2_IT0_IRQHandler so a multi-bus gateway
 * (system_full sysnode) can own FDCAN2 as its second bus. comm_glue.c provides the STRONG
 * handler there. A single-bus or CAN-less image never arms FDCAN2, so this weak stub is never
 * entered — it exists only so the link resolves the vector's symbol. The linker prefers the
 * strong comm_glue.c definition when present.
 *
 * Why a separate object and NOT a weak alias inside vectors.S: a same-object `.weak`/`.set`
 * alias captures the vector .word's relocation, the real handler goes unreferenced, and
 * --gc-sections deletes it — every edge-bus frame then spins the core in __tx_BadHandler
 * (cost a bench day on FDCAN1, then FDCAN2). A weak *function* in its own object is overridden
 * cleanly by the strong definition (verified by objdump of the vector table). */

__attribute__((weak)) void FDCAN2_IT0_IRQHandler(void) { }

/* IRQ125 = HSEM1 (CM7 cross-core doorbell). The image whose comm thread consumes a cross-core
 * [[bulk]] pool provides the strong HSEM1_IT_IRQHandler (posts the comm wake semaphore); every
 * other image (incl. the CM4 satellite, which never enables this NVIC line) gets this weak stub
 * so the shared vector's symbol resolves. Separate object, same reason as above. */
__attribute__((weak)) void HSEM1_IT_IRQHandler(void) { }

/* Cross-core CpuLoad (xcore.h XCORE_LOAD_ADDR): a satellite image publishes its per-mille load and the
 * owner reads it, so the CpuLoad frame reports every core. Weak no-op/zero defaults so an image
 * that does neither — a single-core node, or the retiring standalone dual-core examples — links
 * without them; the H755 domain's glue overrides both strongly. Same weak-in-a-shared-object
 * pattern as the IRQ stubs above (this object is on every image's BSP). */
#include <stdint.h>
__attribute__((weak)) void xcore_load_pub(int core, uint16_t pm) { (void)core; (void)pm; }
__attribute__((weak)) uint16_t xcore_load_get(int core) { (void)core; return 0u; }
