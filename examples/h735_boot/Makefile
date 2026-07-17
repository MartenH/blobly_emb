# h735_boot — the boot manager, single-bank sector 0 (docs/bootloader.md). Bare
# metal (no kernel): board bring-up + the single-bank flash driver + the CAN
# backend + the transpiled boot/isotp stack. TARGET SKELETON — compiles; the
# H735 flash.c is bench-unverified (the H755 twin is silicon-verified).
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../..
NAME    := $(notdir $(CURDIR))

BOARD := h735dk
include $(REPO)/boards/$(BOARD)/board.mk

CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) $(CAN_DEFS) -DBOARD_ENTRY=main__main \
          -I. $(BOARD_INCS) -I$(REPO)/driver/can $(CMSIS)
# __flash_len__ = BOOT_SIZE (sector 0, 128 KB): the linker refuses an image that
# outgrows the boot region instead of letting `make flash` overflow into APP_BASE
# and destroy the installed app (codex emb#140). Keep in lockstep with bootmap.h.
LDFLAGS = $(MCU) -T $(BOARD_LD_BARE) -nostartfiles -Wl,--gc-sections \
          -Wl,--defsym,__flash_len__=0x20000 \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/boot.map

BUILD = build
BSP = $(BOARD_BSP_BARE) boot_glue.c $(BOARD_DIR)/flash.c $(REPO)/driver/can/can_backend.c

all: $(BUILD)/$(NAME).bin

$(BUILD)/boot.c: main.v $(wildcard $(REPO)/boot/*.v) $(wildcard $(REPO)/bcrypto/*.v) $(wildcard $(REPO)/comm/isotp/*.v) $(wildcard $(REPO)/comm/uds/*.v) | $(BUILD)
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
	st-flash $(if $(H735),--serial $(H735),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(H735),--serial $(H735),) reset

clean:
	rm -rf $(BUILD)

.PHONY: all flash clean

# a failed recipe (the vinit lint) must not leave its half-made target: GNU make only
# deletes targets on error when asked (make manual, Errors in Recipes)
.DELETE_ON_ERROR:
