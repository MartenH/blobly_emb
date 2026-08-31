# boards/h755zi — NUCLEO-H755ZI-Q, Cortex-M7 side: 400 MHz (VOS1 — the -Q SMPS supply
# rules out the 480 MHz VOS0 point), HSE 8 MHz bypass from the ST-LINK MCO, I-cache on.
# FDCAN1 on PD0 (RX) / PD1 (TX), Zio CN9 — EXTERNAL transceiver required (TLE9251V on
# jumper wires; the Nucleo populates none). Dual-core part; this is CM7-only for now
# (the CM4 is not started — multicore is the next rung).
#
# Select with:
#     BOARD := h755zi
#     include $(REPO)/boards/$(BOARD)/board.mk
BOARD_DIR    := $(REPO)/boards/h755zi
BOARD_COMMON := $(REPO)/boards/common

MCU        = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CMSIS      = -I$(REPO)/third_party/cmsis_device_h7/Include \
             -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include
# CORE_CM7: the dual-core device header needs to know which core it is compiled for.
BOARD_DEFS = -DSTM32H755xx -DCORE_CM7 -DTRACE_CPU_MHZ=400 -DSYSTEM_CLOCK=400000000
# FDCAN timing off the 8 MHz HSE kernel clock: nominal 500 kbit = 16 tq (NBRP 1, 81.25%). Also
# FD-capable — data 2 Mbit = 4 tq (DBRP 1, 1+2+1, 75%) — so a fd=true node here opens rather than
# parking (loom2v allows FD on any board now). NOTE 75% != the 80 MHz edge boards' 80%: this
# board is not on the FD edge bus; harmonize to 80 MHz PLL2 before putting it on one.
# 16 tq/bit (1 + 12 + 3), sample point 81.25%.
CAN_DEFS   = -DBLOB_CAN_FDCAN -DBLOB_FDCAN_KCLK_HZ=8000000 -DBLOB_FDCAN_TQ=16 \
             -DBLOB_FDCAN_NTSEG1=12 -DBLOB_FDCAN_NTSEG2=3 \
             -DBLOB_FDCAN_DBITRATE=2000000 -DBLOB_FDCAN_DTQ=4 -DBLOB_FDCAN_DTSEG1=2 -DBLOB_FDCAN_DTSEG2=1 -DBLOB_FDCAN_DSJW=1
# driver/io GPIO backend (register-level, io_stm32.c). On-board: LD1 = PB0, B1 = PC13.
IO_DEFS    = -DBLOB_IO_STM32

BOARD_BSP_THREADX = $(BOARD_COMMON)/crt0.S $(BOARD_COMMON)/vectors.S \
                    $(BOARD_COMMON)/tx_initialize_low_level.S $(BOARD_COMMON)/weak_irq.c $(BOARD_DIR)/board.c
BOARD_BSP_BARE    = $(BOARD_COMMON)/startup.c $(BOARD_DIR)/board.c
BOARD_LD_THREADX  = $(BOARD_DIR)/threadx.ld
BOARD_LD_BARE     = $(BOARD_DIR)/bare.ld
BOARD_INCS        = -I$(BOARD_DIR) -I$(BOARD_COMMON)

# --- the OTHER core: Cortex-M4 (flash bank 2 @ 0x08100000, D2 SRAM) -------------------
# No board.c: the CM7 owns RCC/PWR (one core initializes the clock tree, the other must
# never touch it); a CM4 image is startup + app only. Shared memory = D3 SRAM4
# (0x38000000, 64K) — uncached on both cores by policy, so no coherency management.
MCU_CM4        = -mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard -mthumb
# SYSTEM_CLOCK for the CM4 = HCLK after the CM7's bring-up (400/2); it must not configure
# SysTick before the CM7 signals clocks-ready (duo.h) or the tick is 3.125x off.
BOARD_DEFS_CM4 = -DSTM32H755xx -DCORE_CM4 -DTRACE_CPU_MHZ=200 -DSYSTEM_CLOCK=200000000
BOARD_BSP_CM4_BARE    = $(BOARD_COMMON)/startup.c
BOARD_LD_CM4_BARE     = $(BOARD_DIR)/cm4_bare.ld
BOARD_BSP_CM4_THREADX = $(BOARD_COMMON)/crt0.S $(BOARD_COMMON)/vectors.S \
                        $(BOARD_COMMON)/weak_irq.c $(BOARD_COMMON)/tx_initialize_low_level.S
BOARD_LD_CM4_THREADX  = $(BOARD_DIR)/cm4_threadx.ld
