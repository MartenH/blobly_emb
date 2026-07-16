# h755_threadx — the full generated ThreadX target on the NUCLEO-H755ZI-Q (CM7 side):
# the same ecu.toml stack as examples/h735_threadx (shell, trace, NM, the 3-thread load
# demo), re-based onto boards/h755zi (400 MHz VOS1, FDCAN1 on PD0/PD1 via an external
# TLE9251V — see boards/h755zi/board.mk). The point of this example: the whole toolchain
# on the second board BEFORE waking the CM4, so multicore bring-up is debuggable with
# our own tools (shell ps/bmc, trace chart) rather than gdb alone. loom2v's
# [target] kind="threadx" emitter wraps the FB superloop in a ThreadX thread; this build
# transpiles the V stack to freestanding C and links it with the vendored ThreadX kernel
# + the H735 board bring-up (the shared recorder from examples/threadx_h735) + the register-level FDCAN
# backend. The generated counterpart of the hand-written examples/threadx_h735.
#
#   make -C ../.. deps      # once: ThreadX + CMSIS
#   make flash              # st-flash the .bin
#   candump can0            # watch the CpuLoad (0x7E0) + LoadDetail (0x7E1) telemetry
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../..
NAME    := $(notdir $(CURDIR))
TX       = $(REPO)/third_party/threadx
PORT     = $(TX)/ports/cortex_m7/gnu

# The board (clock/flash/I-cache bring-up, startup, vectors, FDCAN timing, linker script)
# comes from boards/$(BOARD) — MCU/CMSIS/BOARD_DEFS/CAN_DEFS/BOARD_BSP_*/BOARD_LD_*.
BOARD := h755zi
include $(REPO)/boards/$(BOARD)/board.mk

# TX_ENABLE_EXECUTION_CHANGE_NOTIFY makes the ThreadX port's context-switch + SysTick asm call
# the four _tx_execution_* hooks (trace_hooks.c) — the source of the real thread/ISR trace.
# BOARD_ENTRY: crt0 jumps into the generated V image's main__main.
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) -DTX_ENABLE_EXECUTION_CHANGE_NOTIFY -DBOARD_ENTRY=main__main $(CAN_DEFS) \
          -I. -Igen $(BOARD_INCS) -I$(REPO)/driver/can -I$(PORT)/inc -I$(TX)/common/inc $(CMSIS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map
# APP_LINK=boot: link at APP_VECTORS (bootmap.h APP_BASE 0x08020000 + 0x400) for the
# bootloader chain; wrap the .bin with tools/mkimage --pad-vectors before flashing.
# The link mode is PART OF THE ARTIFACT: the stamp below forces a relink when it
# changes, so `make APP_LINK=boot` can never reuse a stale standalone .elf whose
# vectors still point at 0x08000000 (codex on emb#130).
ifeq ($(APP_LINK),boot)
# __flash_len__ = APP_SIZE(0xE0000) - vector pad(0x400) - signature(0x40): the
# signed container is header ‖ image ‖ 64-byte sig, so the app must leave 64 bytes
# at the top of the slot or a max-size signed image overflows the boot's region
# check (codex on emb#137).
LDFLAGS += -Wl,--defsym,__flash_base__=0x08020400 -Wl,--defsym,__flash_len__=0xDFBC0
LINKMODE = boot
else
LINKMODE = std
endif
LINKSTAMP = $(BUILD)/link.$(LINKMODE).stamp

BUILD    = build
TX_A     = $(BUILD)/tx.a
TX_ASM   = $(wildcard $(PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))

# board bring-up (asm + board.c) + the exec-change trace recorder, the shared recorder from
# boards/common (trace_hooks.c is driver-independent — pure recorder).
BSP = $(BOARD_BSP_THREADX) comm_glue.c $(REPO)/boards/common/trace_hooks.c \
      $(BOARD_DIR)/flash.c

all: $(BUILD)/$(NAME).bin

# 0) generate the ThreadX target (gen/ports/sig) from ecu.toml via loom2v.
GEN = gen/loom_gen.v ports/ports_gen.v sig/signals_gen.v
gen: gen/.stamp
gen/.stamp: ecu.toml bus.dbc $(wildcard $(REPO)/examples/shared/loadmix/app/*.v) $(REPO)/tools/ecucheck/gen.v $(wildcard $(REPO)/tools/loom2v/*.v) $(REPO)/tools/ecumodel/model.v
	@mkdir -p gen ports sig
	cd $(REPO) && $(V) run tools/ecucheck/gen.v examples/$(NAME)/ecu.toml
	cd $(REPO) && $(V) run tools/loom2v examples/$(NAME)/ecu.toml examples/$(NAME)/bus.dbc \
	  examples/$(NAME)/sig/signals_gen.v examples/$(NAME)/ports/ports_gen.v examples/$(NAME)/gen/loom_gen.v \
	  examples/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

# loom's fixed Scheduler tables, right-sized to this image's real per-thread handler count
# (loom2v derives LOOM_VDEFS = -d loom_max_tasks=N; loom.v defaults to 32 without it).
-include gen/loom_build.mk

# 1) transpile the V stack to freestanding C (-enable-globals for the ThreadX TCB/stack statics).
$(BUILD)/app.c: main.v gen/.stamp $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) $(wildcard $(REPO)/driver/can/*.v) $(wildcard $(REPO)/nvm/*.v) $(wildcard $(REPO)/boot/*.v) $(wildcard $(REPO)/examples/shared/loadmix/app/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|examples/$(NAME)|examples/shared/loadmix" \
	  -o examples/$(NAME)/$(BUILD)/app.c examples/$(NAME)/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# 2) ThreadX kernel objects (same as examples/threadx_h735).
$(BUILD)/tx/%.o: $(PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

# 3) cross-compile + link: generated app.c + board bring-up + CAN backend + ThreadX kernel.
$(LINKSTAMP): | $(BUILD)
	@rm -f $(BUILD)/link.*.stamp
	@touch $@

$(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(REPO)/driver/can/can_backend.c $(TX_A) $(BOARD_LD_THREADX) $(LINKSTAMP)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) $(REPO)/driver/can/can_backend.c $(TX_A) -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
ifeq ($(APP_LINK),boot)
	$(error a boot-linked image is not standalone: wrap it (tools/mkimage --pad-vectors) and deliver via the boot manager — flashing this .bin at 0x08000000 would overwrite the bootloader with vectors that point into the app slot)
else
	st-flash write $(BUILD)/$(NAME).bin 0x08000000
	st-flash reset
endif

clean:
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash clean

# a failed recipe (the vinit lint) must not leave its half-made target: GNU make only
# deletes targets on error when asked (make manual, Errors in Recipes)
.DELETE_ON_ERROR:
