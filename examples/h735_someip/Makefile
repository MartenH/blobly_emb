# examples/h735_someip — SOME/IP on the H735-DK through the FULL loom2v
# pipeline (docs/someip.md target rung): ecu.toml -> generated FB thread + eth
# comm thread over the NetX seam (driver/eth/eth_netx.c). Retires the
# hand-wired netx_glue rung; the wire is byte-identical to examples/host_someip.
#
#   make -C ../.. deps      # once: ThreadX + NetX Duo + CMSIS
#   make flash H735=<stlink-serial>
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
V       ?= v
REPO     = ../..
NAME    := $(notdir $(CURDIR))
TX       = $(REPO)/third_party/threadx
TX_PORT  = $(TX)/ports/cortex_m7/gnu
NX       = $(REPO)/third_party/netxduo
NX_PORT  = $(NX)/ports/cortex_m7/gnu

BOARD := h735dk
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

# board bring-up + ETH MAC + the NetX STM32H7 driver + the shared NetX eth
# backend + this image's byte-IOC glue
BSP = $(BOARD_BSP_THREADX) $(REPO)/boards/$(BOARD)/eth.c \
      $(REPO)/net/nx_driver_stm32h7.c $(REPO)/driver/eth/eth_netx.c $(REPO)/boards/common/iocb.c

# a failed lint must not leave a linkable app.c behind (the vinit gate is mandatory)
.DELETE_ON_ERROR:

all: $(BUILD)/$(NAME).bin

# 0) generate the ThreadX target (gen/ports/sig) from ecu.toml via loom2v.
gen: gen/.stamp
gen/.stamp: ecu.toml $(REPO)/tools/ecucheck/gen.v $(wildcard $(REPO)/tools/loom2v/*.v) $(REPO)/tools/ecumodel/model.v
	@mkdir -p gen ports sig
	cd $(REPO) && $(V) run tools/ecucheck/gen.v examples/$(NAME)/ecu.toml
	cd $(REPO) && $(V) run tools/loom2v examples/$(NAME)/ecu.toml examples/$(NAME)/bus.dbc \
	  examples/$(NAME)/sig/signals_gen.v examples/$(NAME)/ports/ports_gen.v examples/$(NAME)/gen/loom_gen.v \
	  examples/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

-include gen/loom_build.mk
# remake rule: after `make clean`, regenerating via gen/.stamp must make GNU
# make RESTART and reparse the include — without this rule LOOM_VDEFS stays
# unset for the same run and Loom compiles its default 32-handler tables
gen/loom_build.mk: gen/.stamp ;

# 1) transpile the V stack to freestanding C (-enable-globals: ThreadX TCB/stack statics).
$(BUILD)/app.c: main.v gen/.stamp $(wildcard app/*.v) $(wildcard $(REPO)/loom/*.v) $(wildcard $(REPO)/comm/*/*.v) | $(BUILD)
	cd $(REPO) && $(V) -freestanding -gc none -no-bounds-checking -enable-globals $(LOOM_VDEFS) \
	  -path "@vlib|@vmodules|.|examples/$(NAME)" \
	  -o examples/$(NAME)/$(BUILD)/app.c examples/$(NAME)/main.v
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

# 3) cross-compile + link. ioc.h is a PROTOCOL contract compiled into
# boards/common/iocb.c and eth_netx.c — a header change must rebuild, or
# `make flash` ships stale IOC code against fresh generated expectations.
$(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(TX_A) $(NX_A) $(BOARD_LD_THREADX) $(REPO)/boards/common/ioc.h
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) \
	  -Wl,--start-group $(TX_A) $(NX_A) -Wl,--end-group -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	@mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(H735),--serial $(H735),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(H735),--serial $(H735),) reset

clean:
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash clean
