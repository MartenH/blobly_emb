  .global reset_handler

  .global __tx_NMIHandler
  .global __tx_BadHandler
  .global __tx_SVCallHandler
  .global __tx_DBGHandler
  .global __tx_PendSVHandler
  .global __tx_SysTickHandler
  .global __tx_BadHandler

  .syntax unified
  .section .vectors, "ax"
  .code 16
  .align 0
  .global _vectors

_vectors:
  .word __stack_end__
  .word reset_handler
  .word __tx_NMIHandler
  .word __tx_HardfaultHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word 0 // Reserved
  .word 0 // Reserved
  .word 0 // Reserved
  .word 0 // Reserved
  .word __tx_SVCallHandler    //_SVC_Handler - used by Threadx scheduler //
  .word __tx_DBGHandler
  .word 0 // Reserved
  .word __tx_PendSVHandler
  .word __tx_SysTickHandler   // Used by Threadx timer functionality
  .word __tx_BadHandler       // IRQ0  (Populate with user Interrupt handlers)
  .word __tx_BadHandler       // IRQ1
  .word __tx_BadHandler       // IRQ2
  .word __tx_BadHandler       // IRQ3
  .word __tx_BadHandler       // IRQ4
  .word __tx_BadHandler       // IRQ5
  .word __tx_BadHandler       // IRQ6
  .word __tx_BadHandler       // IRQ7
  .word __tx_BadHandler       // IRQ8
  .word __tx_BadHandler       // IRQ9
  .word __tx_BadHandler       // IRQ10
  .word __tx_BadHandler       // IRQ11
  .word __tx_BadHandler       // IRQ12
  .word __tx_BadHandler       // IRQ13
  .word __tx_BadHandler       // IRQ14
  .word __tx_BadHandler       // IRQ15
  .word __tx_BadHandler       // IRQ16
  .word __tx_BadHandler       // IRQ17
  .word __tx_BadHandler       // IRQ18
  /* IRQ19 = FDCAN1 interrupt line 0 (Rx FIFO0) -> vector id 35. The image must provide the
   * handler: comm_glue.c on a bus-owning core, a trivial stub on a CAN-less one (m4_glue.c).
   * NEVER weak-alias it here: a same-object `.weak`+`.set` default captures this .word's
   * relocation, the real handler goes unreferenced, --gc-sections deletes it, and every
   * received CAN frame spins the core in __tx_BadHandler (a full bench day, 2026-07-12). */
  .word FDCAN1_IT0_IRQHandler
  /* IRQ20 = FDCAN2 interrupt line 0 (Rx FIFO0) -> vector id 36. A multi-bus gateway
   * (system_full sysnode) owns FDCAN2 as its second bus; comm_glue.c provides the strong
   * handler. weak_irq.c gives a weak default so a single-bus / CAN-less image (which never
   * arms FDCAN2) still links. Same rule as FDCAN1 above: the strong handler must be linked,
   * NEVER weak-aliased in THIS object, or --gc-sections deletes it and every edge-bus frame
   * spins the core in __tx_BadHandler (the FDCAN1 bench day, and the FDCAN2 one: 2026-07-26). */
  .word FDCAN2_IT0_IRQHandler // IRQ20
  .word __tx_BadHandler       // IRQ21
  .word __tx_BadHandler       // IRQ22
  .word __tx_BadHandler       // IRQ23
  .word __tx_BadHandler       // IRQ24
  .word __tx_BadHandler       // IRQ25
  .word __tx_BadHandler       // IRQ26
  .word __tx_BadHandler       // IRQ27
  .word __tx_BadHandler       // IRQ28
  .word __tx_BadHandler       // IRQ29
  .word __tx_BadHandler       // IRQ30
  .word __tx_BadHandler       // IRQ31
  .word __tx_BadHandler       // IRQ32
  .word __tx_BadHandler       // IRQ33
  .word __tx_BadHandler       // IRQ34
  .word __tx_BadHandler       // IRQ35
  .word __tx_BadHandler       // IRQ36
  .word __tx_BadHandler       // IRQ37
  .word __tx_BadHandler       // IRQ38
  .word __tx_BadHandler       // IRQ39
  .word __tx_BadHandler       // IRQ40
  .word __tx_BadHandler       // IRQ41
  .word __tx_BadHandler       // IRQ42
  .word __tx_BadHandler       // IRQ43
  .word __tx_BadHandler       // IRQ44
  .word __tx_BadHandler       // IRQ45
  .word __tx_BadHandler       // IRQ46
  .word __tx_BadHandler       // IRQ47
  .word __tx_BadHandler       // IRQ48
  .word __tx_BadHandler       // IRQ49
  .word __tx_BadHandler       // IRQ50
  .word __tx_BadHandler       // IRQ51
  .word __tx_BadHandler       // IRQ52
  .word __tx_BadHandler       // IRQ53
  .word __tx_BadHandler       // IRQ54
  .word __tx_BadHandler       // IRQ55
  .word __tx_BadHandler       // IRQ56
  .word __tx_BadHandler       // IRQ57
  .word __tx_BadHandler       // IRQ58
  .word __tx_BadHandler       // IRQ59
  .word __tx_BadHandler       // IRQ60
  /* IRQ61 = ETH global interrupt (RM0468 NVIC id 61). Same rule as FDCAN1_IT0
   * above: the image provides the strong handler (boards/h735dk/eth.c). Non-net
   * images fall back to the WEAK ETH_IRQHandler in their board.c — a SEPARATE
   * object, so it never captures this .word's relocation the way a same-object
   * .weak+.set would (the --gc-sections trap the FDCAN note warns about). */
  .word ETH_IRQHandler        // IRQ61

  .section .init, "ax"
  .thumb_func
reset_handler:
  // low level hardware config, such as PLL setup goes here
  b _start



