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
