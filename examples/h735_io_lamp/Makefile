# h735_io_lamp — the rx half of the cross-node button demo on the STM32H735G-DK:
# examples/h755_io sends its B1 button as ButtonState (0x310); this node's comm
# thread receives it and the RemoteLamp FB mirrors it onto LD2 (PC3) through the
# generated platform io thread (driver/io STM32 backend, selected by $(IO_DEFS)
# from boards/h735dk/board.mk). The examples/h755_io Makefile shape with
# BOARD := h735dk; loom2v + ecucheck only — no host artifacts on target.
#
#   make -C ../.. deps      # once: ThreadX + CMSIS
#   make flash              # st-flash the .bin
#   press B1 on the h755 node -> LD2 follows on this board.
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
BOARD := h735dk
include $(REPO)/boards/$(BOARD)/board.mk

# BOARD_ENTRY: crt0 jumps into the generated V image's main__main.
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) -DBOARD_ENTRY=main__main $(CAN_DEFS) $(IO_DEFS) \
          -I. -Igen $(BOARD_INCS) -I$(REPO)/driver/can -I$(REPO)/driver/io \
          -I$(PORT)/inc -I$(TX)/common/inc $(CMSIS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD    = build
TX_A     = $(BUILD)/tx.a
TX_ASM   = $(wildcard $(PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))

# board bring-up (asm + board.c) + the IOC-pool/comm/io glue.
BSP = $(BOARD_BSP_THREADX) io_glue.c

all: $(BUILD)/$(NAME).bin

# 0) generate the ThreadX target (gen/ports/sig) from ecu.toml via loom2v.
GEN = gen/loom_gen.v ports/ports_gen.v sig/signals_gen.v
gen: gen/.stamp
gen/.stamp: ecu.toml bus.dbc $(wildcard app/*.v) $(REPO)/tools/ecucheck/gen.v $(wildcard $(REPO)/tools/loom2v/*.v) $(REPO)/tools/ecumodel/model.v
	@mkdir -p gen ports sig
	cd $(REPO) && $(V) run tools/ecucheck/gen.v examples/$(NAME)/ecu.toml
	cd $(REPO) && $(V) run tools/loom2v examples/$(NAME)/ecu.toml examples/$(NAME)/bus.dbc \
	  examples/$(NAME)/sig/signals_gen.v examples/$(NAME)/ports/ports_gen.v examples/$(NAME)/gen/loom_gen.v \
	  examples/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

# loom's fixed Scheduler tables, right-sized to this image's real handler count.
-include gen/loom_build.mk

# 1) transpile the V stack to freestanding C (-enable-globals for the ThreadX TCB/stack statics).
$(BUILD)/app.c: main.v gen/.stamp $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) $(wildcard $(REPO)/driver/can/*.v) $(wildcard $(REPO)/driver/io/*.v) $(wildcard app/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|examples/$(NAME)" \
	  -o examples/$(NAME)/$(BUILD)/app.c examples/$(NAME)/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# 2) ThreadX kernel objects (same as examples/h735_threadx).
$(BUILD)/tx/%.o: $(PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

# 3) cross-compile + link: generated app.c + board bring-up + CAN/IO backends + ThreadX.
$(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A) $(BOARD_LD_THREADX)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A) -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(H735),--serial $(H735),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(H735),--serial $(H735),) reset

clean:
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash clean

# a failed recipe (the vinit lint) must not leave its half-made target: GNU make only
# deletes targets on error when asked (make manual, Errors in Recipes)
.DELETE_ON_ERROR:
