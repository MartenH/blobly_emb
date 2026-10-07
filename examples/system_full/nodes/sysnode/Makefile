# sysnode — the system_full Central Gateway, built as a real ThreadX image (like every other
# node). The comm thread owns both FDCAN buses and forwards the resolved routes; the eth thread
# publishes the gateway's GwStatus on the tel SOME/IP segment (app/: the GwHealth FB) and the
# doip threads carry its diagnostic server, all at the address system.toml gives it. The
# gen step keeps dbcmerge (one merged.dbc across compute/edge, so both frames of every
# route resolve in one DBC); the build is the same ThreadX cross-build the leaf nodes use.
#
# SILICON NOTE: the H735-DK is a 3-FDCAN part, so the driver opens FDCAN1/2/3 by index and
# boards/common/comm_glue.c arms all three Rx interrupts. boards/h735dk currently muxes FDCAN1 pins only —
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
NX       = $(REPO)/third_party/netxduo
NX_PORT  = $(NX)/ports/cortex_m7/gnu
include $(REPO)/boards/$(BOARD)/board.mk
# repo tools are built once into bin/ and run from there, never `v run` (tools/tools.mk, #333)
include $(REPO)/tools/tools.mk

# DoIP ([doip] in ecu.toml) runs NetX Duo on the H735's Ethernet. Tick rate: 1 kHz SysTick;
# nx_port.h hard-defines NX_IP_PERIODIC_RATE=100, so both must be forced or every NetX timeout
# runs 10x fast (bench-paid on h735_net P1).
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) -DBOARD_ENTRY=main__main $(CAN_DEFS) \
          -DTX_TIMER_TICKS_PER_SECOND=1000 -DNX_IP_PERIODIC_RATE=1000 \
          -I. -Igen $(BOARD_INCS) -I$(REPO)/driver/can -I$(REPO)/driver/eth \
          -I$(PORT)/inc -I$(TX)/common/inc -I$(NX_PORT)/inc -I$(NX)/common/inc $(CMSIS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD    = build
TX_A     = $(BUILD)/tx.a
TX_CMD   = $(CC) $(CFLAGS)
TX_ASM   = $(wildcard $(PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))
NX_A     = $(BUILD)/nx.a
NX_CMD   = $(CC) $(CFLAGS)
NX_C     = $(wildcard $(NX)/common/src/*.c)
NX_OBJ   = $(patsubst $(NX)/common/src/%.c,$(BUILD)/nx/%.o,$(NX_C))
# the kernel and the network stack resolve each other: one archive group
LINKLIBS = -Wl,--start-group $(TX_A) $(NX_A) -Wl,--end-group
# + the network the config asks for (gen/loom_build.mk: ETH MAC, NetX driver, driver/eth seams)
BSP      = $(BOARD_BSP_THREADX) $(LOOM_GLUE_SRCS) $(REPO)/boards/common/trace_hooks.c \
           $(LOOM_NET_SRCS) $(LOOM_FAULT_SRCS) $(LOOM_DISPLAY_SRCS)

all: $(BUILD)/$(NAME).bin

gen: gen/.stamp
# Generators are built from source into bin/ ($(TOOL_x), tools/tools.mk) — a clean checkout has
# the V sources, not prebuilt binaries — and the gen-system sub-make builds sysgen the same way
# in the repo root. Both DBCs are prerequisites: an edit to either must re-merge and re-gen.
# The generator SOURCES are prerequisites too: a stale-tool build would silently re-validate
# code emitted by the old sysgen/dbcmerge/dbc2cfg/loom2v (AGENTS.md target-verification path).
GENSRC = $(wildcard $(REPO)/tools/ecucheck/*.v) $(wildcard $(REPO)/tools/sysgen/*.v) $(wildcard $(REPO)/tools/dbcmerge/*.v) \
         $(wildcard $(REPO)/tools/dbc2cfg/*.v) $(wildcard $(REPO)/tools/loom2v/*.v) \
         $(wildcard $(REPO)/tools/ecumodel/*.v) $(wildcard $(REPO)/tools/doipcfg/*.v) \
         $(wildcard $(REPO)/tools/candb/*.v) $(wildcard $(REPO)/tools/sysmodel/*.v) \
         $(wildcard $(REPO)/comm/doip/*.v) $(wildcard $(REPO)/comm/uds/*.v)
# (comm/doip and comm/uds: the generators import them — DoIP policy defaults and limits, UDS
# table bounds — so a change there must regenerate, not only recompile)
# Every node's ecu.toml: gen-system validates them all, and a segment peer is derived from who
# reads which event — so the bench tool's ecu.toml decides where GwStatus goes.
gen/.stamp: $(SYSDIR)/system.toml $(wildcard $(SYSDIR)/nodes/*/ecu.toml) $(wildcard app/*.v) $(SYSDIR)/compute.dbc $(SYSDIR)/edge.dbc $(GENSRC) $(TOOL_dbc2cfg) $(TOOL_dbcmerge) $(TOOL_loom2v)
	@mkdir -p gen ports sig
	$(MAKE) -C $(REPO) gen-system SYSTEM=examples/system_full/system.toml
	cd $(REPO) && $(TOOL_dbcmerge) $(GW)/gen/merged.dbc examples/system_full/compute.dbc examples/system_full/edge.dbc
	cd $(REPO) && $(TOOL_dbc2cfg) $(GW)/gen/merged.dbc $(GW)/gen/dbc_gen.v
	cd $(REPO) && $(TOOL_loom2v) examples/system_full/gen-$(NAME).toml $(GW)/gen/merged.dbc \
	  $(GW)/sig/signals_gen.v $(GW)/ports/ports_gen.v $(GW)/gen/loom_gen.v $(GW)/gen/trace-manifest.csv
	@touch gen/.stamp

# loom2v writes gen/loom_build.mk (LOOM_VDEFS, LOOM_NET_SRCS); this rule makes make RESTART and
# reparse the include once gen has run, or both stay unset for the same run
# (not for clean, which would otherwise regenerate everything before deleting it)
ifneq ($(MAKECMDGOALS),clean)
-include gen/loom_build.mk
endif
CFLAGS += $(LOOM_DISPLAY_DEFS) # [display]: LVGL's include path (empty without one)
CFLAGS += $(LOOM_NET_DEFS) # the network the config sizes (driver/eth/netx_up.c)
gen/loom_build.mk: gen/.stamp ;

# how V is run for it — also its signature (tools/tools.mk v_sign)
TRANSPILE_FLAGS = -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) -path "@vlib|@vmodules|.|$(GW)"
$(BUILD)/app.c: $(SYSDIR)/main.v gen/.stamp $(call v_unrecorded,$(BUILD)/app.c) $(call v_sign,$(BUILD)/app.c,$(TRANSPILE_FLAGS)) | $(BUILD)
	cd $(REPO) && $(V) $(TRANSPILE_FLAGS) $(call v_dump,$@) -o $(GW)/$(BUILD)/app.c examples/system_full/main.v
	$(call v_deps,$@)
# what V compiled into it (tools/tools.mk v_deps)
-include $(BUILD)/app.c.d

$(BUILD)/tx/%.o: $(PORT)/src/%.S $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/tx,$$(TX_CMD))
	@mkdir -p $(BUILD)/tx
	$(call c_object,$(TX_CMD))
$(BUILD)/tx/%.o: $(TX)/common/src/%.c $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/tx,$$(TX_CMD))
	@mkdir -p $(BUILD)/tx
	$(call c_object,$(TX_CMD))
$(TX_A): $(TX_OBJ) $$(call c_sign,$$@,$$(AR_CMD))
	$(call c_archive,$(AR_CMD))
-include $(call c_records,$(TX_OBJ))
$(BUILD)/nx/%.o: $(NX)/common/src/%.c $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/nx,$$(NX_CMD))
	@mkdir -p $(BUILD)/nx
	$(call c_object,$(NX_CMD))
$(NX_A): $(NX_OBJ) $$(call c_sign,$$@,$$(AR_CMD))
	$(call c_archive,$(AR_CMD))
-include $(call c_records,$(NX_OBJ))

APPO_CMD = $(CC) $(CFLAGS) -w -c $(BUILD)/app.c
$(BUILD)/app.o: $(BUILD)/app.c $(call c_unrecorded,$(BUILD)/app.o) $$(call c_sign,$$@,$$(APPO_CMD))
	$(call c_build,$(APPO_CMD))
-include $(BUILD)/app.o.d

ELF_CMD = $(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(LINKLIBS)
$(BUILD)/$(NAME).elf: $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(TX_A) $(NX_A) $(BOARD_LD_THREADX) $(call c_unrecorded,$(BUILD)/$(NAME).elf) $$(call c_sign,$$@,$$(ELF_CMD))
	$(call c_build,$(ELF_CMD))
	$(SIZE) $@
	@$(REPO)/scripts/lint_vinit.sh $@   # the _vinit-trap gate (host CI can't cross-compile; run it here)
-include $(BUILD)/$(NAME).elf.d

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

# behind its bootloader ([boot]: boot/boot.mk, included by gen/loom_build.mk) the application
# goes to the app slot with the boot beside it; standalone, the image is the whole flash
ifeq ($(BOOT_ON),1)
flash: boot-flash
else
flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(SERIAL),--serial $(SERIAL),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(SERIAL),--serial $(SERIAL),) reset
endif

clean:
	rm -rf $(BUILD) gen ports sig bin

.PHONY: all gen flash clean
.DELETE_ON_ERROR:
