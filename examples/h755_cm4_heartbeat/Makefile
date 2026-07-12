# CM4 heartbeat for the NUCLEO-H755ZI-Q — flash bank 2 (0x08100000), the second core's
# first image. Build/flash independently of the CM7 image in bank 1:
#     make flash          # st-flash to bank 2; a reset then boots BOTH cores
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
REPO     = ../..
NAME     = h755_cm4_heartbeat

BOARD := h755zi
include $(REPO)/boards/$(BOARD)/board.mk

CFLAGS  = $(MCU_CM4) -ffreestanding -Os -g -ffunction-sections -fdata-sections \
          $(CMSIS) $(BOARD_INCS) $(BOARD_DEFS_CM4) -DBOARD_ENTRY=cm4_main
LDFLAGS = $(MCU_CM4) -T $(BOARD_LD_CM4_BARE) -nostartfiles --specs=nano.specs --specs=nosys.specs \
          -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(NAME).map

BUILD = build

all: $(BUILD)/$(NAME).bin

$(BUILD)/$(NAME).elf: main.c $(BOARD_BSP_CM4_BARE) $(BOARD_LD_CM4_BARE) | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) main.c $(BOARD_BSP_CM4_BARE) -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash write $(BUILD)/$(NAME).bin 0x08100000
	st-flash reset

clean:
	rm -rf $(BUILD)

.PHONY: all flash clean
