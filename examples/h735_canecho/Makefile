# STM32H735G-DK bare-metal CAN echo (FDCAN1, register-level driver, no HAL).
# Pipeline: V -freestanding -> C, then arm-none-eabi-gcc links it with the board
# bring-up, the startup, and the CAN backend (driver/can, -DBLOB_CAN_FDCAN).
# Needs: arm-none-eabi-gcc (+ newlib), the CMSIS headers (make -C ../.. deps),
# and a flasher (st-flash / probe-rs).

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

# CAN backend = register-level FDCAN; kernel clock = HSE 25 MHz, so 10 tq/bit
# (NBRP 5, tseg1 7 + tseg2 2 = 80% sample) keeps the prescaler integer at 500 kbit.
INCS = -I$(REPO)/third_party/cmsis_device_h7/Include \
       -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include \
       -I$(REPO)/driver/can
DEFS = -DSTM32H735xx -DBLOB_CAN_FDCAN \
       -DBLOB_FDCAN_KCLK_HZ=25000000 -DBLOB_FDCAN_TQ=10 \
       -DBLOB_FDCAN_NTSEG1=7 -DBLOB_FDCAN_NTSEG2=2

MCU      = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CFLAGS   = $(MCU) -ffreestanding $(OPT) $(CDBG) -ffunction-sections -fdata-sections $(INCS) $(DEFS) -include board.h
LDFLAGS  = $(MCU) -T linker.ld -nostartfiles --specs=nano.specs --specs=nosys.specs \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/canecho.map
OOCD_CFG = -f interface/stlink.cfg -f target/stm32h7x.cfg

BUILD    = build
CSRC     = $(BUILD)/canecho.c startup.c board.c $(REPO)/driver/can/can_backend.c

all: $(BUILD)/canecho.bin

# 1) transpile the V echo loop to freestanding C. Run from the repo root so the
#    `import driver.can` module resolves via -path; output back into build/.
$(BUILD)/canecho.c: main.v | $(BUILD)
	cd $(REPO) && $(V) $(VDBG) -freestanding -gc none -no-bounds-checking -path "@vlib|@vmodules|." \
	  -o examples/h735_canecho/$(BUILD)/canecho.c examples/h735_canecho/main.v

# 2) cross-compile + link: V output + startup + board shim + CAN backend
$(BUILD)/canecho.elf: $(CSRC) linker.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/canecho.c startup.c board.c $(REPO)/driver/can/can_backend.c -o $@
	$(SIZE) $@

# 3) raw binary for the flasher
$(BUILD)/canecho.bin: $(BUILD)/canecho.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

# onboard ST-LINK-V3E. (WSL: attach via usbipd, or flash the .bin from Windows.)
flash: $(BUILD)/canecho.bin
	st-flash write $(BUILD)/canecho.bin 0x08000000

debug:
	$(MAKE) clean
	$(MAKE) DEBUG=1 all

gdbserver:
	openocd $(OOCD_CFG)

gdb: $(BUILD)/canecho.elf
	$(GDB) $< -ex "target extended-remote :3333" -ex "load" -ex "break main__main" -ex "continue"

clean:
	rm -rf $(BUILD)

.PHONY: all flash debug gdbserver gdb clean
