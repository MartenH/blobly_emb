# boards/h735dk — STM32H735G-DK: Cortex-M7 @ 550 MHz (VOS0, HSE 25 MHz bypass, I-cache on),
# FDCAN1 on the DK's CAN connector. An example selects the board with
#     BOARD := h735dk
#     include $(REPO)/boards/$(BOARD)/board.mk
# and links $(BOARD_BSP_THREADX)+$(BOARD_LD_THREADX) (ThreadX runtime: crt0/vectors/systick
# glue; -DBOARD_ENTRY=main__main for a generated V image, -DSYSTICK_HZ=<hz> for a non-1kHz
# tick) or $(BOARD_BSP_BARE)+$(BOARD_LD_BARE) (bare-metal superloop: C startup).
BOARD_DIR    := $(REPO)/boards/h735dk
BOARD_COMMON := $(REPO)/boards/common

MCU        = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CMSIS      = -I$(REPO)/third_party/cmsis_device_h7/Include \
             -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include
BOARD_DEFS = -DSTM32H735xx -DTRACE_CPU_MHZ=550 -DSYSTEM_CLOCK=550000000
# FDCAN timing for classic 500 kbit off the 25 MHz HSE kernel clock (10 tq: 1+7+2)
CAN_DEFS   = -DBLOB_CAN_FDCAN -DBLOB_FDCAN_KCLK_HZ=25000000 -DBLOB_FDCAN_TQ=10 \
             -DBLOB_FDCAN_NTSEG1=7 -DBLOB_FDCAN_NTSEG2=2
# driver/io GPIO backend (register-level, io_stm32.c).
IO_DEFS    = -DBLOB_IO_STM32

# startup/vectors/systick glue + the board.h API are family-generic: boards/common
BOARD_BSP_THREADX = $(BOARD_COMMON)/crt0.S $(BOARD_COMMON)/vectors.S \
                    $(BOARD_COMMON)/tx_initialize_low_level.S $(BOARD_DIR)/board.c
BOARD_BSP_BARE    = $(BOARD_COMMON)/startup.c $(BOARD_DIR)/board.c
BOARD_LD_THREADX  = $(BOARD_DIR)/threadx.ld
BOARD_LD_BARE     = $(BOARD_DIR)/bare.ld
BOARD_INCS        = -I$(BOARD_DIR) -I$(BOARD_COMMON)
