# ThreadX on the STM32H735 (P3c-1 Phase 3). The QEMU foundation (threadx_min) proven,
# now on silicon: the same ThreadX kernel + the four execution-change hooks, retargeted
# with the H735 board clock (board.c, 550 MHz PLL1), H735 linker (flash 0x08000000 / DTCM),
# and DWT-timestamped trace. The bring-up triad (crt0/vectors/tx_initialize_low_level) and
# trace_hooks.c are copied from threadx_min unchanged except SYSTEM_CLOCK = 550 MHz.
#
#   make -C ../.. deps      # once: fetch ThreadX + CMSIS
#   make flash              # st-flash the .bin to the board
#   make semihost           # openocd: reset+run with semihosting -> prints TRACE_DUMP
CROSS  ?= arm-none-eabi-
CC      = $(CROSS)gcc
AR      = $(CROSS)ar
OBJCOPY = $(CROSS)objcopy
SIZE    = $(CROSS)size
REPO    = ../..
TX      = $(REPO)/third_party/threadx
PORT    = $(TX)/ports/cortex_m7/gnu

MCU     = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
# TX_ENABLE_EXECUTION_CHANGE_NOTIFY makes the port's context-switch + ISR-entry asm call
# the four _tx_execution_* hooks (trace_hooks.c). TRACE_CPU_MHZ=550 makes now_us() convert
# DWT cycles to real µs on this board. STM32H735xx + CMSIS are for board.c's clock init.
CMSIS   = -I$(REPO)/third_party/cmsis_device_h7/Include \
          -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          -DTX_ENABLE_EXECUTION_CHANGE_NOTIFY -DTRACE_CPU_MHZ=550 -DSTM32H735xx \
          -I. -I$(PORT)/inc -I$(TX)/common/inc $(CMSIS)
LDFLAGS = $(MCU) -T threadx_h735.ld -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD = build
TX_A  = $(BUILD)/tx.a

# ThreadX kernel = the M7 GNU port asm + the portable common C. tx_misra is provided by
# the port (.S), so drop the common (.c) copy to avoid a duplicate symbol.
TX_ASM = $(wildcard $(PORT)/src/*.S)
TX_C   = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ = $(patsubst $(PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
         $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))

APP = crt0.S vectors.S tx_initialize_low_level.S main.c trace_hooks.c board.c

all: $(BUILD)/threadx_h735.bin

# Depend on the Makefile so a CFLAGS change rebuilds the ThreadX objects (no stale tx.a).
$(BUILD)/tx/%.o: $(PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

$(BUILD)/threadx_h735.elf: $(APP) $(TX_A) threadx_h735.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(APP) $(TX_A) -o $@
	$(SIZE) $@

$(BUILD)/threadx_h735.bin: $(BUILD)/threadx_h735.elf
	$(OBJCOPY) -O binary $< $@

# Flash the raw binary (onboard ST-LINK-V3E). Standalone the semihosting dump HardFaults
# (no debugger to service the bkpt) — use `make semihost` to run it under openocd.
flash: $(BUILD)/threadx_h735.bin
	st-flash write $(BUILD)/threadx_h735.bin 0x08000000
	st-flash reset

# Reset + run the flashed image with semihosting enabled; openocd prints the TRACE_DUMP.
semihost:
	openocd -f interface/stlink.cfg -f target/stm32h7x.cfg \
	  -c "init" -c "reset halt" -c "arm semihosting enable" -c "reset run"

clean:
	rm -rf $(BUILD)

.PHONY: all flash semihost clean
