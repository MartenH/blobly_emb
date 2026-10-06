# system_io node build — h735 (NUCLEO-H755ZI-Q, CM7). Builds THIS node from the
# GENERATED gen-h735.toml (produced by `make gen-system` at the system level), the
# shared threadx entry + IOC glue, and this node's authored app/ FBs. Same io+comm
# threadx pipeline as examples/h735_io, but the config is derived from system.toml.
#
#   make -C ../../../.. gen-system SYSTEM=examples/system_io/system.toml  # once
#   make flash SERIAL=<h735 st-link>
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../../../..
# SYSDIR holds the shared main.v + the generated toml/dbc (no trailing
# comment on the assignment — trailing spaces would word-split $(SYSDIR)/main.v).
SYSDIR = $(REPO)/examples/system_io
NAME    := h735
BOARD   := h735dk
TX       = $(REPO)/third_party/threadx
PORT     = $(TX)/ports/cortex_m7/gnu
include $(REPO)/boards/$(BOARD)/board.mk
# repo tools are built once into bin/ and run from there, never `v run` (tools/tools.mk, #333)
include $(REPO)/tools/tools.mk

CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) -DBOARD_ENTRY=main__main $(CAN_DEFS) $(IO_DEFS) \
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
BSP = $(BOARD_BSP_THREADX) $(LOOM_GLUE_SRCS) $(LOOM_FAULT_SRCS) $(LOOM_DISPLAY_SRCS)

all: $(BUILD)/$(NAME).bin

# 1) loom2v the GENERATED node toml -> this node's gen/ports/sig (no ecucheck here:
# sysgen already gated gen-h735.toml when it produced it).
GEN = gen/loom_gen.v ports/ports_gen.v sig/signals_gen.v
gen: gen/.stamp
gen/.stamp: $(SYSDIR)/gen-h735.toml $(SYSDIR)/body.dbc $(wildcard app/*.v) $(TOOL_loom2v)
	@mkdir -p gen ports sig
	cd $(REPO) && $(TOOL_loom2v) examples/system_io/gen-h735.toml examples/system_io/body.dbc \
	  examples/system_io/nodes/h735/sig/signals_gen.v examples/system_io/nodes/h735/ports/ports_gen.v \
	  examples/system_io/nodes/h735/gen/loom_gen.v examples/system_io/nodes/h735/gen/trace-manifest.csv
	@touch gen/.stamp

gen/loom_build.mk: gen/.stamp
	@touch $@
# (not for clean, which would otherwise regenerate everything before deleting it)
ifneq ($(MAKECMDGOALS),clean)
-include gen/loom_build.mk
endif
CFLAGS += $(LOOM_DISPLAY_DEFS) # [display]: LVGL's include path (empty without one)

# 2) transpile the V stack (shared main.v + this node's app/) to freestanding C.
# how V is run for it — also its signature (tools/tools.mk v_sign)
TRANSPILE_FLAGS = -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) -path "@vlib|@vmodules|.|examples/system_io/nodes/h735"
$(BUILD)/app.c: $(SYSDIR)/main.v gen/.stamp $(call v_unrecorded,$(BUILD)/app.c) $(call v_sign,$(BUILD)/app.c,$(TRANSPILE_FLAGS)) | $(BUILD)
	cd $(REPO) && $(V) $(TRANSPILE_FLAGS) $(call v_dump,$@) -o examples/system_io/nodes/h735/$(BUILD)/app.c examples/system_io/main.v
	$(call v_deps,$@)
	$(REPO)/scripts/lint_vinit.sh $@
# what V compiled into it (tools/tools.mk v_deps)
-include $(BUILD)/app.c.d

# 3) ThreadX kernel objects.
$(BUILD)/tx/%.o: $(PORT)/src/%.S $$(call c_unrecorded,$$@) $$(call c_sign,$(TX_A),$$(TX_CMD))
	@mkdir -p $(BUILD)/tx
	$(call c_object,$(TX_CMD))
$(BUILD)/tx/%.o: $(TX)/common/src/%.c $$(call c_unrecorded,$$@) $$(call c_sign,$(TX_A),$$(TX_CMD))
	@mkdir -p $(BUILD)/tx
	$(call c_object,$(TX_CMD))
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^
-include $(call c_records,$(TX_OBJ))

# app.c is GENERATED V code, and its warnings are all V-codegen artifacts of a
# freestanding build on a 32-bit target: calls to the C glue via `fn C.*` with no
# prototype in this TU (implicit-declaration — V typed them, they link + type-check at
# the definition), and V's dead hosted runtime (dlmalloc/mmap/mem*) casting/comparing
# 32-bit pointers as u64 (never called no-alloc; --gc-sections drops it). None are our
# code and none are fixable in a regenerated file, so compile THIS unit quiet (-w) — the
# hand-written glue (comm_glue.c, board.c, drivers) keeps full warnings.
APPO_CMD = $(CC) $(CFLAGS) -w -c $(BUILD)/app.c
$(BUILD)/app.o: $(BUILD)/app.c $(call c_unrecorded,$(BUILD)/app.o) $$(call c_sign,$$@,$$(APPO_CMD))
	$(call c_build,$(APPO_CMD))
-include $(BUILD)/app.o.d

ELF_CMD = $(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A)
$(BUILD)/$(NAME).elf: $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A) $(BOARD_LD_THREADX) $(call c_unrecorded,$(BUILD)/$(NAME).elf) $$(call c_sign,$$@,$$(ELF_CMD))
	$(call c_build,$(ELF_CMD))
	$(SIZE) $@
-include $(BUILD)/$(NAME).elf.d

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
