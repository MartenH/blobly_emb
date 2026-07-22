# Nucleo-H723ZG bare-metal CAN echo (FDCAN1 via CAN-FD Click, register-level, no HAL).
# Pipeline: V -freestanding -> C, then arm-none-eabi-gcc links it with the board
# bring-up, the startup, and the CAN backend (driver/can, -DBLOB_CAN_FDCAN).
# Needs: arm-none-eabi-gcc (+ newlib), the CMSIS headers (make -C ../.. deps),
# and a flasher (st-flash).

CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
GDB      = $(CROSS)gdb
V       ?= v
REPO     = ../..

ifeq ($(DEBUG),1)
  OPT  = -Og
  CDBG = -g3
else
  OPT  = -Os
  CDBG =
endif
VDBG ?=

# CAN backend = register-level FDCAN; kernel clock = HSE 8 MHz (Nucleo ST-LINK MCO),
# so 16 tq/bit (BRP 1, tseg1 12 + tseg2 3 = 81.25% sample) at 500 kbit — same as the
# Nucleo-H755ZI-Q, an integer prescaler with no HSE crystal fitted.
INCS = -I$(REPO)/third_party/cmsis_device_h7/Include \
       -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include \
       -I$(REPO)/driver/can
DEFS = -DSTM32H723xx -DBLOB_CAN_FDCAN \
       -DBLOB_FDCAN_KCLK_HZ=8000000 -DBLOB_FDCAN_TQ=16 \
       -DBLOB_FDCAN_NTSEG1=12 -DBLOB_FDCAN_NTSEG2=3

MCU      = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CFLAGS   = $(MCU) -ffreestanding $(OPT) $(CDBG) -ffunction-sections -fdata-sections $(INCS) $(DEFS) -include board.h
LDFLAGS  = $(MCU) -T linker.ld -nostartfiles --specs=nano.specs --specs=nosys.specs \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/canecho.map

BUILD    = build
CSRC     = $(BUILD)/canecho.c startup.c board.c $(REPO)/driver/can/can_backend.c

all: $(BUILD)/canecho.bin

# 1) transpile the V echo loop to freestanding C. Run from the repo root so the
#    `import driver.can` module resolves via -path; output back into build/.
$(BUILD)/canecho.c: main.v | $(BUILD)
	cd $(REPO) && $(V) $(VDBG) -freestanding -gc none -no-bounds-checking -path "@vlib|@vmodules|." \
	  -o examples/h723_canecho/$(BUILD)/canecho.c examples/h723_canecho/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# 2) cross-compile + link: V output + startup + board shim + CAN backend
$(BUILD)/canecho.elf: $(CSRC) linker.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/canecho.c startup.c board.c $(REPO)/driver/can/can_backend.c -o $@
	$(SIZE) $@

# 3) raw binary for the flasher
$(BUILD)/canecho.bin: $(BUILD)/canecho.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

# onboard ST-LINK-V3E. Address by serial when several probes are attached.
flash: $(BUILD)/canecho.bin
	st-flash write $(BUILD)/canecho.bin 0x08000000

debug:
	$(MAKE) clean
	$(MAKE) DEBUG=1 all

clean:
	rm -rf $(BUILD)

.PHONY: all flash debug clean

.DELETE_ON_ERROR:
