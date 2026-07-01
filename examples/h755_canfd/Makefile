# STM32H755 (Nucleo-H755ZI-Q) bare-metal two-bus CAN echo — FDCAN1 + FDCAN2,
# register-level driver, no HAL. Same pipeline as h735_canecho.
# Needs: arm-none-eabi-gcc (+ newlib), CMSIS headers (make -C ../.. deps), a flasher.
#
# NOTE: needs a V with the freestanding amd64-asm fix (vlang #27564, on master).
# Stock 0.5.1 emits x86 syscall asm that arm-gcc rejects — update V if it errors on
# `impossible constraint in 'asm'` in builtin__sys_call*.

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

# CAN backend = register-level FDCAN. Kernel clock = HSE 8 MHz (Nucleo-H755 ST-LINK
# MCO), so 8 MHz / 500 kbit = 16 tq (BRP 1) = the driver default — no tseg override.
# STM32H755 is dual-core: -DCORE_CM7 selects the M7 view in the CMSIS headers.
INCS = -I$(REPO)/third_party/cmsis_device_h7/Include \
       -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include \
       -I$(REPO)/driver/can
DEFS = -DSTM32H755xx -DCORE_CM7 -DBLOB_CAN_FDCAN -DBLOB_FDCAN_KCLK_HZ=8000000

MCU      = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CFLAGS   = $(MCU) -ffreestanding $(OPT) $(CDBG) -ffunction-sections -fdata-sections $(INCS) $(DEFS) -include board.h
LDFLAGS  = $(MCU) -T linker.ld -nostartfiles --specs=nano.specs --specs=nosys.specs \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/canfd.map
OOCD_CFG = -f interface/stlink.cfg -f target/stm32h7x.cfg

BUILD    = build
CSRC     = $(BUILD)/canfd.c startup.c board.c $(REPO)/driver/can/can_backend.c

all: $(BUILD)/canfd.bin

# 1) transpile the V echo loop to freestanding C (run from repo root so `import
#    driver.can` resolves via -path; output back into build/).
$(BUILD)/canfd.c: main.v | $(BUILD)
	cd $(REPO) && $(V) $(VDBG) -freestanding -gc none -no-bounds-checking -path "@vlib|@vmodules|." \
	  -o examples/h755_canfd/$(BUILD)/canfd.c examples/h755_canfd/main.v

# 2) cross-compile + link: V output + startup + board shim + CAN backend
$(BUILD)/canfd.elf: $(CSRC) linker.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/canfd.c startup.c board.c $(REPO)/driver/can/can_backend.c -o $@
	$(SIZE) $@

# 3) raw binary for the flasher
$(BUILD)/canfd.bin: $(BUILD)/canfd.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/canfd.bin
	st-flash write $(BUILD)/canfd.bin 0x08000000

debug:
	$(MAKE) clean
	$(MAKE) DEBUG=1 all

gdbserver:
	openocd $(OOCD_CFG)

gdb: $(BUILD)/canfd.elf
	$(GDB) $< -ex "target extended-remote :3333" -ex "load" -ex "break main__main" -ex "continue"

clean:
	rm -rf $(BUILD)

.PHONY: all flash debug gdbserver gdb clean
