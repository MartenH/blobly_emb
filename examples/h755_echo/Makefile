# NUCLEO-H755ZI-Q (CM7) bare-metal CAN echo — the boards/h755zi board smoke test.
# Pipeline: V -freestanding -> C, linked with the board layer (boards/h755zi) and the
# register-level FDCAN backend. External TLE9251V transceiver on PD0/PD1 (Zio CN9).
# Needs: arm-none-eabi-gcc, CMSIS headers (make -C ../.. deps), st-flash.

CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../..
NAME     = h755_echo

# The board (clock/I-cache bring-up, startup, FDCAN timing, linker script) comes from
# boards/$(BOARD) — MCU/CMSIS/BOARD_DEFS/CAN_DEFS/BOARD_BSP_BARE/BOARD_LD_BARE.
BOARD := h755zi
include $(REPO)/boards/$(BOARD)/board.mk

CFLAGS   = $(MCU) -ffreestanding -Os -g -ffunction-sections -fdata-sections \
           $(CMSIS) $(BOARD_INCS) -I$(REPO)/driver/can $(BOARD_DEFS) $(CAN_DEFS) \
           -include $(BOARD_COMMON)/board.h
LDFLAGS  = $(MCU) -T $(BOARD_LD_BARE) -nostartfiles --specs=nano.specs --specs=nosys.specs \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(NAME).map

BUILD    = build
CSRC     = $(BUILD)/$(NAME).c $(BOARD_BSP_BARE) $(REPO)/driver/can/can_backend.c

all: $(BUILD)/$(NAME).bin

$(BUILD)/$(NAME).c: main.v | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -path "@vlib|@vmodules|." \
	  -o examples/$(NAME)/$(BUILD)/$(NAME).c examples/$(NAME)/main.v

$(BUILD)/$(NAME).elf: $(CSRC) $(BOARD_LD_BARE) | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(CSRC) -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash write $(BUILD)/$(NAME).bin 0x08000000
	st-flash reset

clean:
	rm -rf $(BUILD)

.PHONY: all flash clean
