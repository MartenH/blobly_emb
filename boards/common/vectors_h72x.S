/* boards/common/vectors_h72x.S — the ThreadX vector table of the STM32H723/H725/H730/H733/H735
 * (RM0468): IRQ0..IRQ162 (TIM24), 163 lines — 13 more than the H75x, FDCAN3 among them.
 * One table per part FAMILY, each spanning that family's FULL interrupt range: an armed
 * line past the end of the table makes the core fetch a vector out of whatever follows it.
 * Every slot holds __tx_BadHandler unless a handler is named for the interrupt there, under
 * the CMSIS name (FDCAN1_IT0_IRQn -> FDCAN1_IT0_IRQHandler). tools/vectab/vectab_test.v checks
 * each table against the IRQn_Type enum of every part a board.mk links it for: the length, each
 * named slot at its IRQn + 16, and every *_IRQHandler the code defines present at its slot. */

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
  /* IRQ55 = TIM7: the [display] CPU profiler's sampling interrupt (boards/h735dk/cpuprof.c);
   * weak_irq.c defaults it for every image without one — never weak-aliased here (FDCAN1 note) */
  .word TIM7_IRQHandler       // IRQ55
  .word __tx_BadHandler       // IRQ56
  .word __tx_BadHandler       // IRQ57
  .word __tx_BadHandler       // IRQ58
  .word __tx_BadHandler       // IRQ59
  .word __tx_BadHandler       // IRQ60
  /* IRQ61 = ETH global interrupt (RM0468 NVIC id 61). Same rule as FDCAN1_IT0
   * above: the image provides the strong handler (boards/h735dk/eth.c, boards/h723/eth.c). Non-net
   * images fall back to the WEAK ETH_IRQHandler in their board.c — a SEPARATE
   * object, so it never captures this .word's relocation the way a same-object
   * .weak+.set would (the --gc-sections trap the FDCAN note warns about). */
  .word ETH_IRQHandler        // IRQ61
  .word __tx_BadHandler       // IRQ62
  .word __tx_BadHandler       // IRQ63
  .word __tx_BadHandler       // IRQ64
  .word __tx_BadHandler       // IRQ65
  .word __tx_BadHandler       // IRQ66
  .word __tx_BadHandler       // IRQ67
  .word __tx_BadHandler       // IRQ68
  .word __tx_BadHandler       // IRQ69
  .word __tx_BadHandler       // IRQ70
  .word __tx_BadHandler       // IRQ71
  .word __tx_BadHandler       // IRQ72
  .word __tx_BadHandler       // IRQ73
  .word __tx_BadHandler       // IRQ74
  .word __tx_BadHandler       // IRQ75
  .word __tx_BadHandler       // IRQ76
  .word __tx_BadHandler       // IRQ77
  .word __tx_BadHandler       // IRQ78
  .word __tx_BadHandler       // IRQ79
  .word __tx_BadHandler       // IRQ80
  .word __tx_BadHandler       // IRQ81
  .word __tx_BadHandler       // IRQ82
  .word __tx_BadHandler       // IRQ83
  .word __tx_BadHandler       // IRQ84
  .word __tx_BadHandler       // IRQ85
  .word __tx_BadHandler       // IRQ86
  .word __tx_BadHandler       // IRQ87
  .word __tx_BadHandler       // IRQ88
  .word __tx_BadHandler       // IRQ89
  .word __tx_BadHandler       // IRQ90
  .word __tx_BadHandler       // IRQ91
  .word __tx_BadHandler       // IRQ92
  .word __tx_BadHandler       // IRQ93
  .word __tx_BadHandler       // IRQ94
  .word __tx_BadHandler       // IRQ95
  .word __tx_BadHandler       // IRQ96
  .word __tx_BadHandler       // IRQ97
  .word __tx_BadHandler       // IRQ98
  .word __tx_BadHandler       // IRQ99
  .word __tx_BadHandler       // IRQ100
  .word __tx_BadHandler       // IRQ101
  .word __tx_BadHandler       // IRQ102
  .word __tx_BadHandler       // IRQ103
  .word __tx_BadHandler       // IRQ104
  .word __tx_BadHandler       // IRQ105
  .word __tx_BadHandler       // IRQ106
  .word __tx_BadHandler       // IRQ107
  .word __tx_BadHandler       // IRQ108
  .word __tx_BadHandler       // IRQ109
  .word __tx_BadHandler       // IRQ110
  .word __tx_BadHandler       // IRQ111
  .word __tx_BadHandler       // IRQ112
  .word __tx_BadHandler       // IRQ113
  .word __tx_BadHandler       // IRQ114
  .word __tx_BadHandler       // IRQ115
  .word __tx_BadHandler       // IRQ116
  .word __tx_BadHandler       // IRQ117
  .word __tx_BadHandler       // IRQ118
  .word __tx_BadHandler       // IRQ119
  .word __tx_BadHandler       // IRQ120
  .word __tx_BadHandler       // IRQ121
  .word __tx_BadHandler       // IRQ122
  .word __tx_BadHandler       // IRQ123
  .word __tx_BadHandler       // IRQ124
  /* IRQ125 = HSEM1 global interrupt (RM0468 NVIC id 125). Single-core part: no cross-core
   * doorbell here, so the weak default in weak_irq.c fills it (the H75x CM7 arms it). */
  .word HSEM1_IRQHandler   // IRQ125
  .word __tx_BadHandler       // IRQ126
  .word __tx_BadHandler       // IRQ127
  .word __tx_BadHandler       // IRQ128
  .word __tx_BadHandler       // IRQ129
  .word __tx_BadHandler       // IRQ130
  .word __tx_BadHandler       // IRQ131
  .word __tx_BadHandler       // IRQ132
  .word __tx_BadHandler       // IRQ133
  .word __tx_BadHandler       // IRQ134
  .word __tx_BadHandler       // IRQ135
  .word __tx_BadHandler       // IRQ136
  .word __tx_BadHandler       // IRQ137
  .word __tx_BadHandler       // IRQ138
  .word __tx_BadHandler       // IRQ139
  .word __tx_BadHandler       // IRQ140
  .word __tx_BadHandler       // IRQ141
  .word __tx_BadHandler       // IRQ142
  .word __tx_BadHandler       // IRQ143
  .word __tx_BadHandler       // IRQ144
  .word __tx_BadHandler       // IRQ145
  .word __tx_BadHandler       // IRQ146
  .word __tx_BadHandler       // IRQ147
  .word __tx_BadHandler       // IRQ148
  .word __tx_BadHandler       // IRQ149
  .word __tx_BadHandler       // IRQ150
  .word __tx_BadHandler       // IRQ151
  .word __tx_BadHandler       // IRQ152
  .word __tx_BadHandler       // IRQ153
  .word __tx_BadHandler       // IRQ154
  .word __tx_BadHandler       // IRQ155
  .word __tx_BadHandler       // IRQ156
  .word __tx_BadHandler       // IRQ157
  .word __tx_BadHandler       // IRQ158
  /* IRQ159 = FDCAN3 interrupt line 0 (RM0468) — a 3-FDCAN part's third bus. comm_glue.c
   * provides the strong handler (#ifdef FDCAN3), weak_irq.c the default; same rule as FDCAN1/2. */
  .word FDCAN3_IT0_IRQHandler // IRQ159
  .word __tx_BadHandler       // IRQ160
  .word __tx_BadHandler       // IRQ161
  .word __tx_BadHandler       // IRQ162 TIM24 — the H72x/H73x's highest

  .section .init, "ax"
  .thumb_func
reset_handler:
  // low level hardware config, such as PLL setup goes here
  b _start



