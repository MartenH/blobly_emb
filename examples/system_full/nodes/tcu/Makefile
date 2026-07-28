# examples/system_full/nodes/tcu — the H723 telematics/Ethernet node through the
# FULL loom2v pipeline (docs/someip.md target rung): ecu.toml -> generated FB thread
# + SOME/IP eth comm thread over the NetX seam (driver/eth/eth_netx.c) + the H723
# board driver (boards/h723/eth.c). Same build recipe as examples/h735_someip; only
# the board (h723) and the node's path depth differ.
#
#   make -C ../../../.. deps      # once: ThreadX + NetX Duo + CMSIS
#   make flash SERIAL=0029003E3233510639363634
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../../../..
NAME    := tcu
EX       = examples/system_full/nodes/$(NAME)
TX       = $(REPO)/third_party/threadx
TX_PORT  = $(TX)/ports/cortex_m7/gnu
NX       = $(REPO)/third_party/netxduo
NX_PORT  = $(NX)/ports/cortex_m7/gnu

BOARD := h723
include $(REPO)/boards/$(BOARD)/board.mk

INCS = $(CMSIS) $(BOARD_INCS) -I$(REPO)/boards/common \
       -I$(TX_PORT)/inc -I$(TX)/common/inc \
       -I$(NX_PORT)/inc -I$(NX)/common/inc
# Tick rate: 1 kHz SysTick; nx_port.h hard-defines NX_IP_PERIODIC_RATE=100, so
# both must be forced or every NetX timeout runs 10x fast (bench-paid on P1).
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          -DTX_TIMER_TICKS_PER_SECOND=1000 -DNX_IP_PERIODIC_RATE=1000 \
          -DBOARD_ENTRY=main__main $(BOARD_DEFS) $(INCS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD  = build
TX_A   = $(BUILD)/tx.a
TX_ASM = $(wildcard $(TX_PORT)/src/*.S)
TX_C   = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ = $(patsubst $(TX_PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
         $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))
NX_A   = $(BUILD)/nx.a
NX_C   = $(wildcard $(NX)/common/src/*.c)
NX_OBJ = $(patsubst $(NX)/common/src/%.c,$(BUILD)/nx/%.o,$(NX_C))

# board bring-up + ETH MAC (H723) + the NetX STM32H7 driver + the shared NetX eth
# backend + the shared byte-IOC glue
BSP = $(BOARD_BSP_THREADX) $(REPO)/boards/$(BOARD)/eth.c \
      $(REPO)/net/nx_driver_stm32h7.c $(REPO)/driver/eth/eth_netx.c $(REPO)/boards/common/iocb.c

# a failed lint must not leave a linkable app.c behind (the vinit gate is mandatory)
.DELETE_ON_ERROR:

all: $(BUILD)/$(NAME).bin

# 0) generate the ThreadX target (gen/ports/sig) from ecu.toml via loom2v.
gen: gen/.stamp
gen/.stamp: ecu.toml $(REPO)/tools/ecucheck/gen.v $(wildcard $(REPO)/tools/loom2v/*.v) $(REPO)/tools/ecumodel/model.v
	@mkdir -p gen ports sig
	cd $(REPO) && $(V) run tools/ecucheck/gen.v $(EX)/ecu.toml
	cd $(REPO) && $(V) run tools/loom2v $(EX)/ecu.toml $(EX)/bus.dbc \
	  $(EX)/sig/signals_gen.v $(EX)/ports/ports_gen.v $(EX)/gen/loom_gen.v \
	  $(EX)/gen/trace-manifest.csv
	@touch gen/.stamp

-include gen/loom_build.mk
# remake rule: after `make clean`, regenerating via gen/.stamp must make GNU make
# RESTART and reparse the include, or LOOM_VDEFS stays unset for the same run.
gen/loom_build.mk: gen/.stamp ;

# 1) transpile the V stack to freestanding C (-enable-globals: ThreadX TCB/stack statics).
$(BUILD)/app.c: main.v gen/.stamp $(wildcard app/*.v) $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|$(EX)" \
	  -o $(EX)/$(BUILD)/app.c $(EX)/main.v
	$(REPO)/scripts/lint_vinit.sh $@

# 2) ThreadX + NetX kernel/stack objects.
$(BUILD)/tx/%.o: $(TX_PORT)/src/%.S Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^
$(BUILD)/nx/%.o: $(NX)/common/src/%.c Makefile
	@mkdir -p $(BUILD)/nx
	$(CC) $(CFLAGS) -c $< -o $@
$(NX_A): $(NX_OBJ)
	$(AR) -rc $@ $^

# 3) cross-compile + link.
# eth.h is a driver-ABI header the BSP .c files include (descriptor counts, buffer sizes) —
# list it as a prereq, or a change there won't relink (codex #247).
$(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(TX_A) $(NX_A) $(BOARD_LD_THREADX) $(REPO)/boards/common/ioc.h $(REPO)/boards/$(BOARD)/eth.h
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) \
	  -Wl,--start-group $(TX_A) $(NX_A) -Wl,--end-group -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	@mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(SERIAL),--serial $(SERIAL),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(SERIAL),--serial $(SERIAL),) reset

clean:
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash clean
