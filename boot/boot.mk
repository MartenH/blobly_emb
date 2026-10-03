# boot/boot.mk — a [boot] node's bootloader, and its application as the bootloader runs it
# (docs/bootloader.md). Included by the node's gen/loom_build.mk, which loom2v writes only for a node
# that declares [boot] — so no Makefile names it, and nothing here is per board or per node:
#   - the boot image is ONE program (boot/target/main.v + boards/common/boot_glue.c), configured by
#     the board's bootmap.h (flash layout, cells) and the node's gen/boot_gen.h (bus, ids, keys);
#   - the application is linked at the board's app slot (APP_VECTORS), read from the same bootmap.h
#     by scripts/boot_layout.sh, so the image, the boot and the app glue cannot disagree.
#
#   make boot                      the boot image, build/boot/boot.bin (sector 0)
#   make image SW_VERSION=<n>      build/<node>.img (field: signed, unmarked — the boot verifies it
#                                  and writes the mark) + build/<node>-factory.img (pre-marked, SWD only)
#   make boot-flash SERIAL=<sn>    SWD: the boot at BOOT_BASE + the factory image at APP_BASE, reset
#
# Needs from the including Makefile: REPO, BUILD, NAME, V, CC, OBJCOPY, SIZE, the board.mk variables
# and tools/tools.mk.
BOOT_GOAL := $(.DEFAULT_GOAL)
# the node runs behind its bootloader: its Makefile's `flash` is boot-flash
BOOT_ON   := 1

# the image containers run tools/mkimage the one way a Makefile runs a repo tool (#333); every
# ThreadX node Makefile includes tools.mk already, so this only covers one that does not
ifndef TOOL_DIR
include $(REPO)/tools/tools.mk
endif

BOOT_DIR     := $(BUILD)/boot
BOOT_LAYOUT   = $(REPO)/scripts/boot_layout.sh '$(CC)' $(BOARD_DIR)
# one layout value; a failure stops the build ($(shell) alone ignores the exit status, and an empty
# app link flag would link the application at 0x08000000)
boot_layout   = $(or $(shell $(BOOT_LAYOUT) $(1)),$(error boot/boot.mk: scripts/boot_layout.sh could not read $(1) from $(BOARD_DIR)/bootmap.h))
SW_VERSION   ?= 1
IMAGE_SEED   ?= $(REPO)/examples/keys/mkimage.seed

# the application at the board's app slot: evaluated when the link runs, never at parse time (a
# host-only `make gen` has no cross compiler to ask)
LDFLAGS += $(call boot_layout,app-ld)
# and relinked when the layout is
$(BUILD)/$(NAME).elf: $(BOARD_DIR)/bootmap.h $(REPO)/scripts/boot_layout.sh

BOOT_CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
               $(BOARD_DEFS) $(CAN_DEFS) -DBOARD_ENTRY=main__main \
               -Igen $(BOARD_INCS) -I$(REPO)/driver/can $(CMSIS)
# the boot may not outgrow its region: the link fails instead of the flash overwriting APP_BASE
BOOT_LDFLAGS = $(MCU) -T $(BOARD_LD_BARE) -nostartfiles -Wl,--gc-sections \
               -Wl,--defsym,__flash_len__=$(call boot_layout,boot-size) \
               --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BOOT_DIR)/boot.map
BOOT_SRCS    = $(BOARD_BSP_BARE) $(REPO)/boards/common/boot_glue.c $(REPO)/boards/common/diag_board.c \
               $(BOARD_FLASH) $(REPO)/driver/can/can_backend.c
BOOT_VSRC    = $(wildcard $(REPO)/boot/target/*.v $(REPO)/boot/*.v $(REPO)/bcrypto/*.v \
               $(REPO)/comm/isotp/*.v $(REPO)/comm/uds/*.v $(REPO)/driver/can/*.v)

boot: $(BOOT_DIR)/boot.bin
# the node's image set is its application AND its bootloader
all: boot

$(BOOT_DIR):
	mkdir -p $(BOOT_DIR)

$(BOOT_DIR)/boot.c: $(BOOT_VSRC) | $(BOOT_DIR)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals \
	  -path "@vlib|@vmodules|." -o $(CURDIR)/$@ boot/target/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# every header and textually included backend (can_backend.c includes can_fdcan.c) comes from the
# compiler's own dependency output, written as the image links — no hand list to miss the next one
$(BOOT_DIR)/boot.elf: $(BOOT_DIR)/boot.c gen/boot_gen.h $(BOOT_SRCS) $(BOARD_LD_BARE) $(REPO)/scripts/boot_layout.sh
	$(CC) $(BOOT_CFLAGS) $(BOOT_LDFLAGS) $(BOOT_DIR)/boot.c $(BOOT_SRCS) -o $@
	$(CC) $(BOOT_CFLAGS) -MM -MP -MT $@ $(BOOT_SRCS) > $(BOOT_DIR)/boot.d
	$(SIZE) $@
-include $(BOOT_DIR)/boot.d

$(BOOT_DIR)/boot.bin: $(BOOT_DIR)/boot.elf
	$(OBJCOPY) -O binary $< $@

# both containers from the one application binary; always remade (SW_VERSION is not a file)
image: $(BUILD)/$(NAME).bin $(TOOL_mkimage)
	$(TOOL_mkimage) $(BUILD)/$(NAME).bin $(BUILD)/$(NAME).img $(SW_VERSION) --pad-vectors --sign $(IMAGE_SEED) --key $(BOOT_IMAGE_KEY)
	$(TOOL_mkimage) $(BUILD)/$(NAME).bin $(BUILD)/$(NAME)-factory.img $(SW_VERSION) --pad-vectors --valid

boot-flash: boot image
	st-flash $(if $(SERIAL),--serial $(SERIAL),) write $(BOOT_DIR)/boot.bin $(call boot_layout,boot-base)
	st-flash $(if $(SERIAL),--serial $(SERIAL),) write $(BUILD)/$(NAME)-factory.img $(call boot_layout,app-base)
	st-flash $(if $(SERIAL),--serial $(SERIAL),) reset

.PHONY: boot image boot-flash
.DEFAULT_GOAL := $(BOOT_GOAL)
