# Minimal ThreadX Cortex-M7 foundation (P3c-1 Phase 1). Builds the vendored ThreadX
# kernel (third_party/threadx — `make -C ../.. deps` fetches it, pinned) for Cortex-M7
# plus a 2-thread demo, and runs it under QEMU mps2-an500. The board bring-up
# (crt0/vectors/tx_initialize_low_level/linker) is copied from the port example and is
# ours to adapt for the H735 next. No trace yet — that's Phase 2.
#
#   make -C ../.. deps      # once: fetch ThreadX
#   make run                # build + run under QEMU (prints A/B as the threads schedule)
CROSS  ?= arm-none-eabi-
CC      = $(CROSS)gcc
AR      = $(CROSS)ar
REPO    = ../..
TX      = $(REPO)/third_party/threadx
PORT    = $(TX)/ports/cortex_m7/gnu

MCU     = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
# TX_ENABLE_EXECUTION_CHANGE_NOTIFY makes the port's context-switch + ISR-entry asm call
# the four _tx_execution_* hooks (trace_hooks.c) — the source of the real trace records.
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          -DTX_ENABLE_EXECUTION_CHANGE_NOTIFY \
          -I$(PORT)/inc -I$(TX)/common/inc
LDFLAGS = $(MCU) -T threadx.ld -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs

BUILD = build
TX_A  = $(BUILD)/tx.a

# ThreadX kernel = the M7 GNU port asm + the portable common C. tx_misra is provided by
# the port (.S), so drop the common (.c) copy to avoid a duplicate symbol.
TX_ASM = $(wildcard $(PORT)/src/*.S)
TX_C   = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
         $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))

APP = crt0.S vectors.S tx_initialize_low_level.S main.c trace_hooks.c

all: $(BUILD)/threadx_min.elf

# Depend on the Makefile so a CFLAGS change (e.g. enabling the execution-change hooks)
# rebuilds the ThreadX objects — otherwise a stale phase-1 tx.a (no hooks) would linger.
$(BUILD)/tx/%.o: $(PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

$(BUILD)/threadx_min.elf: $(APP) $(TX_A) threadx.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(APP) $(TX_A) -o $@

run: $(BUILD)/threadx_min.elf
	qemu-system-arm -M mps2-an500 -cpu cortex-m7 -kernel $< -semihosting -nographic -monitor none -serial none

clean:
	rm -rf $(BUILD)

.PHONY: all run clean
