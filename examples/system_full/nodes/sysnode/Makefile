# sysnode — the system_full Central Gateway, built as a real ThreadX image (like every other
# node). The comm thread owns all three FDCAN buses and forwards the 8 resolved routes. The
# gen step keeps dbcmerge (one merged.dbc across compute/edge, so both frames of every
# route resolve in one DBC); the build is the same ThreadX cross-build the leaf nodes use.
#
# SILICON NOTE: the H735-DK is a 3-FDCAN part, so the driver opens FDCAN1/2/3 by index and
# comm_glue.c arms all three Rx interrupts. boards/h735dk currently muxes FDCAN1 pins only —
# a full 3-transceiver bench bring-up (FDCAN2/3 pin init + external transceivers) is the
# remaining hardware step; the image builds and its routing is exercised on host vcan.
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../../../..
SYSDIR   = $(REPO)/examples/system_full
GW       = examples/system_full/nodes/sysnode
NAME    := sysnode
BOARD   := h735dk
TX       = $(REPO)/third_party/threadx
PORT     = $(TX)/ports/cortex_m7/gnu
include $(REPO)/boards/$(BOARD)/board.mk

CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) -DBOARD_ENTRY=main__main $(CAN_DEFS) \
          -I. -Igen $(BOARD_INCS) -I$(REPO)/driver/can \
          -I$(PORT)/inc -I$(TX)/common/inc $(CMSIS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD    = build
TX_A     = $(BUILD)/tx.a
TX_ASM   = $(wildcard $(PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))
BSP      = $(BOARD_BSP_THREADX) $(REPO)/boards/common/comm_glue.c $(REPO)/boards/common/trace_hooks.c

all: $(BUILD)/$(NAME).bin

gen: gen/.stamp
# Generators run via `$(V) run tools/<t>/gen.v` — a clean checkout has the V sources, not the
# prebuilt binaries. Both DBCs are prerequisites: an edit to either must re-merge and re-gen.
# The generator SOURCES are prerequisites too: a stale-tool build would silently re-validate
# code emitted by the old sysgen/dbcmerge/dbc2cfg/loom2v (AGENTS.md target-verification path).
GENSRC = $(wildcard $(REPO)/tools/sysgen/*.v) $(wildcard $(REPO)/tools/dbcmerge/*.v) \
         $(wildcard $(REPO)/tools/dbc2cfg/*.v) $(wildcard $(REPO)/tools/loom2v/*.v) \
         $(wildcard $(REPO)/tools/ecumodel/*.v) \
         $(wildcard $(REPO)/tools/candb/*.v) $(wildcard $(REPO)/tools/sysmodel/*.v)
gen/.stamp: $(SYSDIR)/system.toml ecu.toml $(SYSDIR)/compute.dbc $(SYSDIR)/edge.dbc $(GENSRC)
	@mkdir -p gen ports sig
	$(MAKE) -C $(REPO) gen-system SYSTEM=examples/system_full/system.toml
	cd $(REPO) && $(V) run tools/dbcmerge/gen.v $(GW)/gen/merged.dbc examples/system_full/compute.dbc examples/system_full/edge.dbc
	cd $(REPO) && $(V) run tools/dbc2cfg/gen.v $(GW)/gen/merged.dbc $(GW)/gen/dbc_gen.v
	cd $(REPO) && $(V) run tools/loom2v examples/system_full/gen-$(NAME).toml $(GW)/gen/merged.dbc \
	  $(GW)/sig/signals_gen.v $(GW)/ports/ports_gen.v $(GW)/gen/loom_gen.v $(GW)/gen/trace-manifest.csv
	@touch gen/.stamp

$(BUILD)/app.c: $(SYSDIR)/main.v gen/.stamp $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) $(wildcard $(REPO)/driver/can/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|$(GW)" \
	  -o $(GW)/$(BUILD)/app.c examples/system_full/main.v

$(BUILD)/tx/%.o: $(PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

$(BUILD)/app.o: $(BUILD)/app.c Makefile
	$(CC) $(CFLAGS) -w -c $< -o $@

$(BUILD)/$(NAME).elf: $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(TX_A) $(BOARD_LD_THREADX)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(TX_A) -o $@
	$(SIZE) $@
	@$(REPO)/scripts/lint_vinit.sh $@   # the _vinit-trap gate (host CI can't cross-compile; run it here)

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(SERIAL),--serial $(SERIAL),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(SERIAL),--serial $(SERIAL),) reset

clean:
	rm -rf $(BUILD) gen ports sig bin

.PHONY: all gen flash clean
.DELETE_ON_ERROR:
