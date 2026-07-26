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
# Regenerate when a GENERATOR changes too, not only the configs/DBCs/app: a stale-tool build
# would silently re-validate code emitted by the old sysgen/dbc2cfg/loom2v (AGENTS.md target-
# image verification path). Generators run via `$(V) run` (a clean checkout has the V sources).
GENSRC = $(wildcard $(REPO)/tools/sysgen/*.v) $(wildcard $(REPO)/tools/dbcmerge/*.v) \
         $(wildcard $(REPO)/tools/dbc2cfg/*.v) $(wildcard $(REPO)/tools/loom2v/*.v) \
         $(wildcard $(REPO)/tools/ecumodel/*.v) \
         $(wildcard $(REPO)/tools/candb/*.v) $(wildcard $(REPO)/tools/sysmodel/*.v)
gen/.stamp: $(SYSDIR)/system.toml ecu.toml $(SYSDIR)/compute.dbc $(wildcard app/*.v) $(GENSRC)
	@mkdir -p gen ports sig
	$(MAKE) -C $(REPO) gen-system SYSTEM=examples/system_full/system.toml
	cd $(REPO) && $(V) run tools/dbc2cfg/gen.v examples/system_full/compute.dbc examples/system_full/nodes/domain/gen/dbc_gen.v
	cd $(REPO) && $(V) run tools/loom2v examples/system_full/gen-$(NAME).toml examples/system_full/compute.dbc \
	  examples/system_full/nodes/$(NAME)/sig/signals_gen.v examples/system_full/nodes/$(NAME)/ports/ports_gen.v \
	  examples/system_full/nodes/$(NAME)/gen/loom_gen.v examples/system_full/nodes/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

$(BUILD)/app.c: $(SYSDIR)/main.v gen/.stamp $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) $(wildcard $(REPO)/driver/can/*.v) $(wildcard app/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|examples/system_full/nodes/$(NAME)" \
	  -o examples/system_full/nodes/$(NAME)/$(BUILD)/app.c examples/system_full/main.v

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
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash clean
.DELETE_ON_ERROR:
