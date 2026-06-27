# STM32H735G-DK bare-metal blinky.
# Proves the pipeline: V -freestanding -> C -> arm-none-eabi-gcc -> .elf/.bin.
# Needs: arm-none-eabi-gcc (+ newlib), and a flasher (st-flash / probe-rs).

CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
GDB      = $(CROSS)gdb
V       ?= v

# `make` = release; `make debug` (or `make DEBUG=1`) = -Og + DWARF. We debug the
# *C* by default: the generated build/blinky.c plus board.c/startup.c.
# To step the *V* source instead, build with `VDBG=-g` (emits #line back to .v).
ifeq ($(DEBUG),1)
  OPT  = -Og
  CDBG = -g3
else
  OPT  = -Os
  CDBG =
endif
VDBG ?=

MCU      = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CFLAGS   = $(MCU) -ffreestanding $(OPT) $(CDBG) -ffunction-sections -fdata-sections -Wall -include board.h
LDFLAGS  = $(MCU) -T linker.ld -nostartfiles --specs=nano.specs --specs=nosys.specs \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/blinky.map
# OpenOCD: onboard ST-LINK-V3E + STM32H7 target
OOCD_CFG = -f interface/stlink.cfg -f target/stm32h7x.cfg

BUILD    = build
CSRC     = $(BUILD)/blinky.c startup.c board.c

all: $(BUILD)/blinky.bin

# 1) transpile the V superloop to freestanding C (no host compile/link)
$(BUILD)/blinky.c: main.v | $(BUILD)
	$(V) $(VDBG) -freestanding -gc none -o $@ main.v

# 2) cross-compile + link the V output with the startup and board shim
$(BUILD)/blinky.elf: $(CSRC) linker.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/blinky.c startup.c board.c -o $@
	$(SIZE) $@

# 3) raw binary for the flasher
$(BUILD)/blinky.bin: $(BUILD)/blinky.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

# onboard ST-LINK-V3E. (WSL: attach via usbipd, or flash the .bin from Windows.)
flash: $(BUILD)/blinky.bin
	st-flash write $(BUILD)/blinky.bin 0x08000000

# fresh debug build (-Og + DWARF). For the VS Code flow, just F5 (see .vscode).
debug:
	$(MAKE) clean
	$(MAKE) DEBUG=1 all

# CLI debug, terminal 1: gdb server over the onboard ST-LINK
gdbserver:
	openocd $(OOCD_CFG)

# CLI debug, terminal 2: connect, flash, run to main (run `make debug` first)
gdb: $(BUILD)/blinky.elf
	$(GDB) $< -ex "target extended-remote :3333" -ex "load" -ex "break main" -ex "continue"

clean:
	rm -rf $(BUILD)

.PHONY: all flash debug gdbserver gdb clean
