# h755_boot — the boot manager, bank-1 sector 0 (docs/bootloader.md). Bare metal
# (no kernel): board bring-up + the dry-coded flash driver + the CAN backend +
# the transpiled boot/isotp stack. TARGET SKELETON — compiles; bench pass pending.
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../..
NAME    := $(notdir $(CURDIR))

BOARD := h755zi
include $(REPO)/boards/$(BOARD)/board.mk

CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) $(CAN_DEFS) -DBOARD_ENTRY=main__main \
          -I. $(BOARD_INCS) -I$(REPO)/driver/can $(CMSIS)
LDFLAGS = $(MCU) -T $(BOARD_LD_BARE) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/boot.map

BUILD = build
BSP = $(BOARD_BSP_BARE) boot_glue.c $(BOARD_DIR)/flash.c $(REPO)/driver/can/can_backend.c

all: $(BUILD)/$(NAME).bin

$(BUILD)/boot.c: main.v $(wildcard $(REPO)/boot/*.v) $(wildcard $(REPO)/comm/isotp/*.v) $(wildcard $(REPO)/comm/uds/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals \
	  -path "@vlib|@vmodules|.|examples/$(NAME)" \
	  -o examples/$(NAME)/$(BUILD)/boot.c examples/$(NAME)/main.v
	$(REPO)/scripts/lint_vinit.sh $@

$(BUILD)/$(NAME).elf: $(BUILD)/boot.c $(BSP) $(BOARD_LD_BARE)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/boot.c $(BSP) -o $@
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
