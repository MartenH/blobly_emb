# boards/h723 — NUCLEO-H723ZG, Cortex-M7 @ 400 MHz (VOS1; the H723 can reach 550 MHz at
# VOS0, but 400 MHz VOS1 is the safe, bench-unverified default this board ships with — the
# same PLL as the -Q Nucleo), HSE 8 MHz bypass from the ST-LINK MCO, I-cache on. FDCAN1 on
# PD0 (RX) / PD1 (TX), AF9 (Zio CN9) — EXTERNAL transceiver required (a CAN-FD Click or
# TLE9251V on jumper wires; the Nucleo populates none).
#
# Single-core value-line part (no CM4) — simpler than the h755zi it is adapted from. The
# supply is the on-board LDO (not the -Q's Direct SMPS): the one real electrical
# difference, set in board.c.
#
# Select with:
#     BOARD := h723
#     include $(REPO)/boards/$(BOARD)/board.mk
BOARD_DIR    := $(REPO)/boards/h723
BOARD_COMMON := $(REPO)/boards/common

MCU        = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CMSIS      = -I$(REPO)/third_party/cmsis_device_h7/Include \
             -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include
BOARD_DEFS = -DSTM32H723xx -DTRACE_CPU_MHZ=400 -DSYSTEM_CLOCK=400000000
# FDCAN timing off the 80 MHz PLL2_Q kernel clock (see board.c): nominal 500 kbit = 16 tq
# (NBRP 10, 1+12+3, 81.25%), data 2 Mbit = 20 tq (DBRP 2, 1+15+4, 80%).
# 16 tq/bit (1 + 12 + 3), sample point 81.25% — identical to the Nucleo-H755ZI-Q.
CAN_DEFS   = -DBLOB_CAN_FDCAN -DBLOB_FDCAN_KCLK_HZ=80000000 -DBLOB_FDCAN_TQ=16 \
             -DBLOB_FDCAN_NTSEG1=12 -DBLOB_FDCAN_NTSEG2=3 \
             -DBLOB_FDCAN_DBITRATE=2000000 -DBLOB_FDCAN_DTQ=20 -DBLOB_FDCAN_DTSEG1=15 -DBLOB_FDCAN_DTSEG2=4 -DBLOB_FDCAN_DSJW=4
# driver/io GPIO backend (register-level, io_stm32.c).
IO_DEFS    = -DBLOB_IO_STM32

# startup/vectors/systick glue + the board.h API are family-generic: boards/common
BOARD_BSP_THREADX = $(BOARD_COMMON)/crt0.S $(BOARD_COMMON)/vectors.S \
                    $(BOARD_COMMON)/tx_initialize_low_level.S $(BOARD_COMMON)/weak_irq.c $(BOARD_DIR)/board.c
BOARD_BSP_BARE    = $(BOARD_COMMON)/startup.c $(BOARD_DIR)/board.c
BOARD_LD_THREADX  = $(BOARD_DIR)/threadx.ld
BOARD_LD_BARE     = $(BOARD_DIR)/bare.ld
BOARD_INCS        = -I$(BOARD_DIR) -I$(BOARD_COMMON)
