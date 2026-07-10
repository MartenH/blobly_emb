# STM32H735G-DK bare-metal FB + Loom + telemetry showcase — GENERATED from ecu.toml.
# Pipeline: loom2v (ecu.toml + [target] baremetal -> gen/ports/sig) -> V -freestanding
# -> C -> arm-none-eabi-gcc links it with the board bring-up, startup, and the CAN
# backend (driver/can, -DBLOB_CAN_FDCAN). Unlike the host examples there is no COM
# bridge (all signals are partition-local) and no cfg2v/dbc2cfg step — the single-core
# target emitter's gen/loom_gen.v is self-contained.
# Needs: arm-none-eabi-gcc (+ newlib), CMSIS headers (make -C ../.. deps), a flasher.

CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
GDB      = $(CROSS)gdb
V       ?= v
REPO     = ../..
NAME    := $(notdir $(CURDIR))

ifeq ($(DEBUG),1)
  OPT  = -Og
  CDBG = -g3
else
  OPT  = -Os
  CDBG =
endif
VDBG ?=

# CAN backend = register-level FDCAN; kernel clock = HSE 25 MHz, so 10 tq/bit
# (NBRP 5, tseg1 7 + tseg2 2 = 80% sample) keeps the prescaler integer at 500 kbit.
INCS = -I$(REPO)/third_party/cmsis_device_h7/Include \
       -I$(REPO)/third_party/cmsis_core/CMSIS/Core/Include \
       -I$(REPO)/driver/can
DEFS = -DSTM32H735xx -DBLOB_CAN_FDCAN \
       -DBLOB_FDCAN_KCLK_HZ=25000000 -DBLOB_FDCAN_TQ=10 \
       -DBLOB_FDCAN_NTSEG1=7 -DBLOB_FDCAN_NTSEG2=2

MCU      = -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
CFLAGS   = $(MCU) -ffreestanding $(OPT) $(CDBG) -ffunction-sections -fdata-sections $(INCS) $(DEFS) -include board.h
LDFLAGS  = $(MCU) -T linker.ld -nostartfiles --specs=nano.specs --specs=nosys.specs \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/app.map
OOCD_CFG = -f interface/stlink.cfg -f target/stm32h7x.cfg

BUILD    = build
CSRC     = $(BUILD)/app.c startup.c board.c $(REPO)/driver/can/can_backend.c

all: $(BUILD)/app.bin

# 0) generate the single-core target (sig/ports/gen) from ecu.toml via loom2v.
#    [target] baremetal in ecu.toml selects the inline, no-spawn, DWT-timebase emitter.
GEN = gen/loom_gen.v ports/ports_gen.v sig/signals_gen.v
gen: gen/.stamp
# Regenerate when the config, the FBs, OR the generator itself changes.
gen/.stamp: ecu.toml bus.dbc $(wildcard app/*.v) $(REPO)/tools/ecucheck/gen.v $(wildcard $(REPO)/tools/loom2v/*.v) $(REPO)/tools/ecumodel/model.v
	@mkdir -p gen ports sig
	cd $(REPO) && $(V) run tools/ecucheck/gen.v examples/$(NAME)/ecu.toml
	cd $(REPO) && $(V) run tools/loom2v examples/$(NAME)/ecu.toml examples/$(NAME)/bus.dbc \
	  examples/$(NAME)/sig/signals_gen.v examples/$(NAME)/ports/ports_gen.v examples/$(NAME)/gen/loom_gen.v \
	  examples/$(NAME)/gen/trace-manifest.csv
	@touch gen/.stamp

# 1) transpile the V stack (main + generated gen/ports/sig + app + loom/telem/can) to
#    freestanding C. Run from the repo root so `import loom/comm.telem/driver.can`
#    resolve via `.` and the local `import gen/app/ports/sig` via examples/$(NAME).
$(BUILD)/app.c: main.v gen/.stamp | $(BUILD)
	cd $(REPO) && $(V) $(VDBG) -freestanding -gc none -no-bounds-checking \
	  -path "@vlib|@vmodules|.|examples/$(NAME)" \
	  -o examples/$(NAME)/$(BUILD)/app.c examples/$(NAME)/main.v

# 2) cross-compile + link: V output + startup + board shim + CAN backend
$(BUILD)/app.elf: $(CSRC) linker.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c startup.c board.c $(REPO)/driver/can/can_backend.c -o $@
	$(SIZE) $@

# 3) raw binary for the flasher
$(BUILD)/app.bin: $(BUILD)/app.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

# onboard ST-LINK-V3E. (WSL: attach via usbipd, or flash the .bin from Windows.)
flash: $(BUILD)/app.bin
	st-flash write $(BUILD)/app.bin 0x08000000

debug:
	$(MAKE) clean
	$(MAKE) DEBUG=1 all

gdbserver:
	openocd $(OOCD_CFG)

gdb: $(BUILD)/app.elf
	$(GDB) $< -ex "target extended-remote :3333" -ex "load" -ex "break main__main" -ex "continue"

clean:
	rm -rf $(BUILD) gen ports sig

.PHONY: all gen flash debug gdbserver gdb clean
