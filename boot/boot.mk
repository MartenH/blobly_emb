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
# app link flag would link the application at 0x08000000) — wherever the cross compiler RUNS: the
# link's signature (tools/tools.mk c_sign) is taken whenever make reads this file, and a host-only
# `make gen` has no compiler to ask, nor anything to link. Whether it runs is asked of the whole
# $(CC), as written (a wrapper, VAR=val), never of a word parsed out of it.
BOOT_CC_RUNS := $(shell $(CC) --version >/dev/null 2>&1 && echo yes)
boot_layout   = $(if $(BOOT_CC_RUNS),$(or $(shell $(BOOT_LAYOUT) $(1)),$(error boot/boot.mk: scripts/boot_layout.sh could not read $(1) from $(BOARD_DIR)/bootmap.h)))
SW_VERSION   ?= 1
IMAGE_SEED   ?= $(REPO)/examples/keys/mkimage.seed

# the application at the board's app slot: evaluated when the link and its signature are, never
# while this line is read — and the link refuses to run without it, whatever the reason
LDFLAGS += $(call boot_layout,app-ld)
c_check_$(BUILD)/$(NAME).elf = $(if $(call boot_layout,app-ld),,$(error boot/boot.mk: $@ has no app-slot layout — the cross compiler $(CC) does not run, so it would link at 0x08000000))
# and relinked when the layout is
$(BUILD)/$(NAME).elf: $(BOARD_DIR)/bootmap.h $(REPO)/scripts/boot_layout.sh

# A node that serves DoIP too (BOOT_DOIP := 1, written by loom2v for [doip]): its bootloader serves
# the programming session over DoIP beside the bus. The decision and the jump stay kernel-free; the
# stay path enters ThreadX and runs the application's own network seam — NetX (driver/eth/netx_up.c),
# the DoIP entity (driver/eth/doip_netx.c), its loop (driver/doipnet) — with the ThreadX runtime of
# the board (BOARD_BSP_THREADX, BOARD_LD_THREADX) and the node's ThreadX/NetX archives (TX_A, NX_A).
ifeq ($(BOOT_DOIP),1)
BOOT_VDEFS   = -d boot_doip
BOOT_RT_DEFS = -DTX_TIMER_TICKS_PER_SECOND=1000 -DNX_IP_PERIODIC_RATE=1000 -DBLOB_NET_POOL_COUNT=12u \
               -I$(REPO)/third_party/threadx/ports/cortex_m7/gnu/inc -I$(REPO)/third_party/threadx/common/inc \
               -I$(REPO)/third_party/netxduo/ports/cortex_m7/gnu/inc -I$(REPO)/third_party/netxduo/common/inc
BOOT_RT_SRCS = $(BOARD_BSP_THREADX) $(REPO)/boards/$(BOARD)/eth.c $(REPO)/net/nx_driver_stm32h7.c \
               $(REPO)/driver/eth/netx_up.c $(REPO)/driver/eth/doip_netx.c $(REPO)/boards/common/boot_net.c
BOOT_LD      = $(BOARD_LD_THREADX)
BOOT_LIBS    = $(TX_A) $(NX_A)
BOOT_LINKLIBS = -Wl,--start-group $(BOOT_LIBS) -Wl,--end-group
else
BOOT_VDEFS   =
BOOT_RT_DEFS =
BOOT_RT_SRCS = $(BOARD_BSP_BARE) $(REPO)/boards/common/diag_board.c
BOOT_LD      = $(BOARD_LD_BARE)
BOOT_LIBS    =
BOOT_LINKLIBS =
endif

BOOT_CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
               $(BOARD_DEFS) $(CAN_DEFS) -DBOARD_ENTRY=main__main $(BOOT_RT_DEFS) \
               -Igen $(BOARD_INCS) -I$(REPO)/driver/can $(CMSIS)
# the boot may not outgrow its region: the link fails instead of the flash overwriting APP_BASE
BOOT_LDFLAGS = $(MCU) -T $(BOOT_LD) -nostartfiles -Wl,--gc-sections \
               -Wl,--defsym,__flash_len__=$(call boot_layout,boot-size) \
               --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BOOT_DIR)/boot.map
BOOT_SRCS    = $(BOOT_RT_SRCS) $(REPO)/boards/common/boot_glue.c $(BOARD_FLASH) $(REPO)/driver/can/can_backend.c

boot: $(BOOT_DIR)/boot.bin
# the node's image set is its application AND its bootloader
all: boot

$(BOOT_DIR):
	mkdir -p $(BOOT_DIR)

# what V compiles into it is its dependency list (tools/tools.mk v_deps)
# how V is run for it — -d boot_doip on a [doip] node — also its signature (tools/tools.mk v_sign)
BOOT_TRANSPILE_FLAGS = -freestanding -gc none -no-bounds-checking -enable-globals $(BOOT_VDEFS) -path "@vlib|@vmodules|."
$(BOOT_DIR)/boot.c: $(call v_unrecorded,$(BOOT_DIR)/boot.c) $(call v_sign,$(BOOT_DIR)/boot.c,$(BOOT_TRANSPILE_FLAGS)) | $(BOOT_DIR)
	cd $(REPO) && $(V) $(BOOT_TRANSPILE_FLAGS) $(call v_dump,$@) -o $(CURDIR)/$@ boot/target
	$(call v_deps,$@)
	$(REPO)/scripts/lint_vinit.sh $@
-include $(BOOT_DIR)/boot.c.d

# every header (bootmap.h, the generated boot_gen.h) and textually included backend (can_backend.c
# includes can_fdcan.c) comes from the compiler's own dependency output, written as the image links
# (tools/tools.mk c_build, the rule every image's link shares) — no hand list to miss the next one
BOOT_CMD = $(CC) $(BOOT_CFLAGS) $(BOOT_LDFLAGS) $(BOOT_DIR)/boot.c $(BOOT_SRCS) $(BOOT_LINKLIBS)
$(BOOT_DIR)/boot.elf: $(BOOT_DIR)/boot.c $(BOOT_SRCS) $(BOOT_LD) $(BOOT_LIBS) $(REPO)/scripts/boot_layout.sh $(call c_unrecorded,$(BOOT_DIR)/boot.elf) $$(call c_sign,$$@,$$(BOOT_CMD))
	$(call c_build,$(BOOT_CMD))
	$(SIZE) $@
-include $(BOOT_DIR)/boot.elf.d

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
