# examples/h735_someip — SOME/IP events on the H735-DK (docs/someip.md NetX bench rung).
# V side (main.v + comm/someip + comm/e2e) transpiles to freestanding C like
# h735_threadx; the ThreadX+NetX archives and the ETH driver come from the
# h735_net recipe; netx_glue.c is the four-call seam between them.
#
#   make -C ../.. deps      # once: ThreadX + NetX Duo + CMSIS
#   make flash              # then listen for events: broadcast to :30491
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
GDB      = $(CROSS)gdb
V       ?= v
REPO     = ../..
NAME    := $(notdir $(CURDIR))
TX       = $(REPO)/third_party/threadx
TX_PORT  = $(TX)/ports/cortex_m7/gnu
NX       = $(REPO)/third_party/netxduo
NX_PORT  = $(NX)/ports/cortex_m7/gnu

BOARD := h735dk
include $(REPO)/boards/$(BOARD)/board.mk

INCS = $(CMSIS) $(BOARD_INCS) \
       -I$(TX_PORT)/inc -I$(TX)/common/inc \
       -I$(NX_PORT)/inc -I$(NX)/common/inc
# Tick rate: 1 kHz SysTick; nx_port.h hard-defines NX_IP_PERIODIC_RATE=100, so
# both must be forced or every NetX timeout runs 10x fast (bench-paid on P1).
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          -DTX_TIMER_TICKS_PER_SECOND=1000 -DNX_IP_PERIODIC_RATE=1000 \
          -DBOARD_ENTRY=main__main $(BOARD_DEFS) $(INCS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD    = build

# --- ThreadX + NetX archives (identical recipes to h735_net) ---
TX_A     = $(BUILD)/tx.a
TX_ASM   = $(wildcard $(TX_PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(TX_PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))
NX_A     = $(BUILD)/nx.a
NX_C     = $(wildcard $(NX)/common/src/*.c)
NX_OBJ   = $(patsubst $(NX)/common/src/%.c,$(BUILD)/nx/%.o,$(NX_C))

# board bring-up + ETH driver + NetX driver glue + this example's socket glue
BSP  = $(BOARD_BSP_THREADX) $(REPO)/boards/$(BOARD)/eth.c \
       $(REPO)/net/nx_driver_stm32h7.c netx_glue.c

all: $(BUILD)/$(NAME).bin

# 1) transpile the V side (main.v + comm.someip + comm.e2e) to freestanding C.
#    -enable-globals: the __global doip.Server (in-place init, no stack copy).
$(BUILD)/app.c: main.v $(wildcard $(REPO)/comm/someip/*.v) $(wildcard $(REPO)/comm/e2e/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals \
	  -path "@vlib|@vmodules|.|examples/$(NAME)" \
	  -o examples/$(NAME)/$(BUILD)/app.c examples/$(NAME)/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# 2) archives (Makefile dep: NetX behavior hangs on the -D flags above)
$(BUILD)/tx/%.o: $(TX_PORT)/src/%.S Makefile | $(BUILD)
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile | $(BUILD)
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^
$(BUILD)/nx/%.o: $(NX)/common/src/%.c Makefile | $(BUILD)
	@mkdir -p $(BUILD)/nx
	$(CC) $(CFLAGS) -c $< -o $@
$(NX_A): $(NX_OBJ)
	$(AR) -rc $@ $^

# 3) link: V output + glue + BSP + kernel/stack archives (grouped: cross-refs)
$(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(TX_A) $(NX_A) $(BOARD_LD_THREADX) | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) \
	  -Wl,--start-group $(TX_A) $(NX_A) -Wl,--end-group -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(H735),--serial $(H735),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(H735),--serial $(H735),) reset

gdb: $(BUILD)/$(NAME).elf
	$(GDB) $< -ex "target extended-remote :3333" -ex "load" -ex "break main__main" -ex "continue"

clean:
	rm -rf $(BUILD)

.PHONY: all flash gdb clean
# a failed recipe (the vinit lint) must not leave its half-made target
.DELETE_ON_ERROR:
