# h755_io — docs/io.md P1 on the ThreadX target (NUCLEO-H755ZI-Q, CM7 side): the
# generated platform io thread drives the on-board button + LEDs through the
# driver/io STM32 backend (register-level GPIO, selected by $(IO_DEFS) from
# boards/h755zi/board.mk). loom2v emits: io cfg/init + one boot publish at the top
# of tx_application_define (REQ-IO-009: before any thread exists), the io thread
# (AUTO_START OFF, resumed after the boot publish, priority just above the FB
# thread), and the FB superloop in a ThreadX thread — see examples/h755_threadx
# for the full comm-thread stack; this example is the io slice.
#
#   make -C ../.. deps      # once: ThreadX + CMSIS
#   make flash              # st-flash the .bin
#   LD2 (yellow) blinks 1 Hz; B1 lights LD1 (green); CpuLoad 0x7E0 on the bus.
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
# comes from boards/$(BOARD) — MCU/CMSIS/BOARD_DEFS/CAN_DEFS/IO_DEFS/BOARD_BSP_*/BOARD_LD_*.
BOARD := h755zi
include $(REPO)/boards/$(BOARD)/board.mk
# repo tools are built once into bin/ and run from there, never `v run` (tools/tools.mk, #333)
include $(REPO)/tools/tools.mk

# BOARD_ENTRY: crt0 jumps into the generated V image's main__main.
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

# board bring-up (asm + board.c) + the IOC-pool glue (no comm thread in this example).
BSP = $(BOARD_BSP_THREADX) $(LOOM_GLUE_SRCS) $(LOOM_FAULT_SRCS)

all: $(BUILD)/$(NAME).bin

# 0) generate the ThreadX target (gen/ports/sig) from ecu.toml via loom2v.
GEN = gen/loom_gen.v ports/ports_gen.v sig/signals_gen.v
gen: gen/.stamp
gen/.stamp: ecu.toml bus.dbc $(wildcard app/*.v) $(TOOL_ecucheck) $(TOOL_loom2v)
	@mkdir -p gen ports sig
	cd $(REPO) && $(TOOL_ecucheck) examples/$(NAME)/ecu.toml
	cd $(REPO) && $(TOOL_loom2v) examples/$(NAME)/ecu.toml examples/$(NAME)/bus.dbc \
	  examples/$(NAME)/sig/signals_gen.v examples/$(NAME)/ports/ports_gen.v examples/$(NAME)/gen/loom_gen.v \
	  examples/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

# loom's fixed Scheduler tables, right-sized to this image's real handler count.
# (not for clean, which would otherwise regenerate everything before deleting it)
ifneq ($(MAKECMDGOALS),clean)
-include gen/loom_build.mk
endif
# remade by gen: make restarts and rereads it, so a first build sees LOOM_VDEFS / LOOM_FAULT_SRCS
gen/loom_build.mk: gen/.stamp ;

# 1) transpile the V stack to freestanding C (-enable-globals for the ThreadX TCB/stack statics).
# how V is run for it — also its signature (tools/tools.mk v_sign)
TRANSPILE_FLAGS = -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) -path "@vlib|@vmodules|.|examples/$(NAME)"
$(BUILD)/app.c: main.v gen/.stamp $(call v_unrecorded,$(BUILD)/app.c) $(call v_sign,$(BUILD)/app.c,$(TRANSPILE_FLAGS)) | $(BUILD)
	cd $(REPO) && $(V) $(TRANSPILE_FLAGS) $(call v_dump,$@) -o examples/$(NAME)/$(BUILD)/app.c examples/$(NAME)/main.v
	$(call v_deps,$@)
	$(REPO)/scripts/lint_vinit.sh $@
# what V compiled into it (tools/tools.mk v_deps)
-include $(BUILD)/app.c.d

# 2) ThreadX kernel objects (same as examples/h755_threadx).
$(BUILD)/tx/%.o: $(PORT)/src/%.S $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/tx,$$(TX_CMD))
	@mkdir -p $(BUILD)/tx
	$(call c_object,$(TX_CMD))
$(BUILD)/tx/%.o: $(TX)/common/src/%.c $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/tx,$$(TX_CMD))
	@mkdir -p $(BUILD)/tx
	$(call c_object,$(TX_CMD))
$(TX_A): $(TX_OBJ) $$(call c_sign,$$@,$$(AR_CMD))
	$(call c_archive,$(AR_CMD))
-include $(call c_records,$(TX_OBJ))

# 3) cross-compile + link: generated app.c + board bring-up + CAN/IO backends + ThreadX.
# io_backend.c textually includes the STM32 implementation; that and every header reach the
# link through its dependency record (tools/tools.mk c_build), never a hand list
ELF_CMD = $(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A)
$(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A) $(BOARD_LD_THREADX) $(call c_unrecorded,$(BUILD)/$(NAME).elf) $$(call c_sign,$$@,$$(ELF_CMD))
	$(call c_build,$(ELF_CMD))
	$(SIZE) $@
-include $(BUILD)/$(NAME).elf.d

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash write $(BUILD)/$(NAME).bin 0x08000000
	st-flash reset

clean:
	rm -rf $(BUILD) gen ports sig bin

.PHONY: all gen flash clean

# a failed recipe (the vinit lint) must not leave its half-made target: GNU make only
# deletes targets on error when asked (make manual, Errors in Recipes)
.DELETE_ON_ERROR:
