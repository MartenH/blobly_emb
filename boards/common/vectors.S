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
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler
  .word __tx_BadHandler

  .section .init, "ax"
  .thumb_func
reset_handler:
  // low level hardware config, such as PLL setup goes here
  b _start



