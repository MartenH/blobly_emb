CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../../../..
SYSDIR   = $(REPO)/examples/system_full
NAME    := domain
BOARD   := h755zi
TX       = $(REPO)/third_party/threadx
PORT     = $(TX)/ports/cortex_m7/gnu
include $(REPO)/boards/$(BOARD)/board.mk
# repo tools are built once into bin/ and run from there, never `v run` (tools/tools.mk, #333)
include $(REPO)/tools/tools.mk

CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) -DBOARD_ENTRY=main__main -DTX_ENABLE_EXECUTION_CHANGE_NOTIFY $(CAN_DEFS) -DBLOB_IO_STM32 \
          -I. -Igen $(BOARD_INCS) -I$(REPO)/driver/can -I$(REPO)/driver/io \
          -I$(PORT)/inc -I$(TX)/common/inc $(CMSIS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD    = build
TX_A     = $(BUILD)/tx.a
TX_CMD   = $(CC) $(CFLAGS)
TX_ASM   = $(wildcard $(PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))
BSP      = $(BOARD_BSP_THREADX) $(LOOM_GLUE_SRCS) target_ext.c $(REPO)/boards/common/trace_hooks.c $(LOOM_FAULT_SRCS)

all: $(BUILD)/$(NAME).bin

gen: gen/.stamp
# Regenerate when a GENERATOR changes too, not only the configs/DBCs/app: a stale-tool build
# would silently re-validate code emitted by the old sysgen/dbc2cfg/loom2v (AGENTS.md target-
# image verification path). Generators are built from source into bin/ (tools/tools.mk).
GENSRC = $(wildcard $(REPO)/tools/ecucheck/*.v) $(wildcard $(REPO)/tools/sysgen/*.v) $(wildcard $(REPO)/tools/dbcmerge/*.v) \
         $(wildcard $(REPO)/tools/dbc2cfg/*.v) $(wildcard $(REPO)/tools/loom2v/*.v) \
         $(wildcard $(REPO)/tools/ecumodel/*.v) $(wildcard $(REPO)/tools/cfgschema/*.v) \
         $(wildcard $(REPO)/tools/candb/*.v) $(wildcard $(REPO)/tools/sysmodel/*.v)
gen/.stamp: $(SYSDIR)/system.toml ecu.toml $(SYSDIR)/compute.dbc $(wildcard app/*.v) $(GENSRC) $(TOOL_dbc2cfg) $(TOOL_loom2v)
	@mkdir -p gen ports sig
	$(MAKE) -C $(REPO) gen-system SYSTEM=examples/system_full/system.toml
	cd $(REPO) && $(TOOL_dbc2cfg) examples/system_full/compute.dbc examples/system_full/nodes/domain/gen/dbc_gen.v
	cd $(REPO) && $(TOOL_loom2v) examples/system_full/gen-$(NAME).toml examples/system_full/compute.dbc \
	  examples/system_full/nodes/$(NAME)/sig/signals_gen.v examples/system_full/nodes/$(NAME)/ports/ports_gen.v \
	  examples/system_full/nodes/$(NAME)/gen/loom_gen.v examples/system_full/nodes/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

# loom2v writes gen/loom_build.mk (LOOM_VDEFS, LOOM_FAULT_SRCS); this rule makes make RESTART and
# reparse the include once gen has run, or both stay unset for the same run
# (not for clean, which would otherwise regenerate everything before deleting it)
ifneq ($(MAKECMDGOALS),clean)
-include gen/loom_build.mk
endif
gen/loom_build.mk: gen/.stamp ;

# how V is run for it — also its signature (tools/tools.mk v_sign)
TRANSPILE_FLAGS = -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) -path "@vlib|@vmodules|.|examples/system_full/nodes/$(NAME)"
$(BUILD)/app.c: $(SYSDIR)/main.v gen/.stamp $(call v_unrecorded,$(BUILD)/app.c) $(call v_sign,$(BUILD)/app.c,$(TRANSPILE_FLAGS)) | $(BUILD)
	cd $(REPO) && $(V) $(TRANSPILE_FLAGS) $(call v_dump,$@) -o examples/system_full/nodes/$(NAME)/$(BUILD)/app.c examples/system_full/main.v
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

APPO_CMD = $(CC) $(CFLAGS) -w -c $(BUILD)/app.c
$(BUILD)/app.o: $(BUILD)/app.c $(call c_unrecorded,$(BUILD)/app.o) $$(call c_sign,$$@,$$(APPO_CMD))
	$(call c_build,$(APPO_CMD))
-include $(BUILD)/app.o.d

# io_backend.c textually includes the STM32 implementation; that and every header reach the
# link through its dependency record (tools/tools.mk c_build), never a hand list
ELF_CMD = $(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A)
$(BUILD)/$(NAME).elf: $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A) $(BOARD_LD_THREADX) $(call c_unrecorded,$(BUILD)/$(NAME).elf) $$(call c_sign,$$@,$$(ELF_CMD))
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
