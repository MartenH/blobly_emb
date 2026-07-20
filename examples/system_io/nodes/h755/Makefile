# system_io node build — h755 (NUCLEO-H755ZI-Q, CM7). Builds THIS node from the
# GENERATED gen-h755.toml (produced by `make gen-system` at the system level), the
# shared threadx entry + IOC glue, and this node's authored app/ FBs. Same io+comm
# threadx pipeline as examples/h755_io, but the config is derived from system.toml.
#
#   make -C ../../../.. gen-system SYSTEM=examples/system_io/system.toml  # once
#   make flash SERIAL=<h755 st-link>
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../../../..
# SYSDIR holds the shared main.v + io_glue.c + the generated toml/dbc (no trailing
# comment on the assignment — trailing spaces would word-split $(SYSDIR)/main.v).
SYSDIR = $(REPO)/examples/system_io
NAME    := h755
BOARD   := h755zi
TX       = $(REPO)/third_party/threadx
PORT     = $(TX)/ports/cortex_m7/gnu
include $(REPO)/boards/$(BOARD)/board.mk

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
BSP = $(BOARD_BSP_THREADX) $(SYSDIR)/io_glue.c

all: $(BUILD)/$(NAME).bin

# 1) loom2v the GENERATED node toml -> this node's gen/ports/sig (no ecucheck here:
# sysgen already gated gen-h755.toml when it produced it).
GEN = gen/loom_gen.v ports/ports_gen.v sig/signals_gen.v
gen: gen/.stamp
gen/.stamp: $(SYSDIR)/gen-h755.toml $(SYSDIR)/body.dbc $(wildcard app/*.v) $(wildcard $(REPO)/tools/loom2v/*.v)
	@mkdir -p gen ports sig
	cd $(REPO) && $(V) run tools/loom2v examples/system_io/gen-h755.toml examples/system_io/body.dbc \
	  examples/system_io/nodes/h755/sig/signals_gen.v examples/system_io/nodes/h755/ports/ports_gen.v \
	  examples/system_io/nodes/h755/gen/loom_gen.v examples/system_io/nodes/h755/gen/trace-manifest.csv
	@touch gen/.stamp

gen/loom_build.mk: gen/.stamp
	@touch $@
-include gen/loom_build.mk

# 2) transpile the V stack (shared main.v + this node's app/) to freestanding C.
$(BUILD)/app.c: $(SYSDIR)/main.v gen/.stamp $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) $(wildcard $(REPO)/driver/can/*.v) $(wildcard $(REPO)/driver/io/*.v) $(wildcard app/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|examples/system_io/nodes/h755" \
	  -o examples/system_io/nodes/h755/$(BUILD)/app.c examples/system_io/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# 3) ThreadX kernel objects.
$(BUILD)/tx/%.o: $(PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

# app.c is GENERATED V code, and its warnings are all V-codegen artifacts of a
# freestanding build on a 32-bit target: calls to the C glue via `fn C.*` with no
# prototype in this TU (implicit-declaration — V typed them, they link + type-check at
# the definition), and V's dead hosted runtime (dlmalloc/mmap/mem*) casting/comparing
# 32-bit pointers as u64 (never called no-alloc; --gc-sections drops it). None are our
# code and none are fixable in a regenerated file, so compile THIS unit quiet (-w) — the
# hand-written glue (io_glue.c, board.c, drivers) keeps full warnings.
$(BUILD)/app.o: $(BUILD)/app.c Makefile
	$(CC) $(CFLAGS) -w -c $< -o $@

$(BUILD)/$(NAME).elf: $(BUILD)/app.o $(BSP) $(REPO)/boards/common/ioc.h $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(REPO)/driver/io/io_stm32.c $(REPO)/driver/io/io_port.h $(TX_A) $(BOARD_LD_THREADX)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.o $(BSP) $(REPO)/driver/can/can_backend.c $(REPO)/driver/io/io_backend.c $(TX_A) -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(SERIAL),--serial $(SERIAL),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(SERIAL),--serial $(SERIAL),) reset

clean:
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash clean
.DELETE_ON_ERROR:
