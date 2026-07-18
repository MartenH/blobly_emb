# examples/h735_net — P1 TCP/IP bring-up (docs/net.md): ThreadX + NetX Duo + the
# register-level ETH driver. A plain C ThreadX app (no loom2v, no CAN, no V) whose
# only job is to prove boards/h735dk/eth.c + net/nx_driver_stm32h7.c on silicon:
# bring the LAN8742 link up and ping the gateway.
#
#   make -C ../.. deps      # once: ThreadX + NetX Duo + CMSIS
#   make flash              # st-flash the .bin, then watch net_ping_ok over SWD
CROSS   ?= arm-none-eabi-
CC       = $(CROSS)gcc
AR       = $(CROSS)ar
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
GDB      = $(CROSS)gdb
REPO     = ../..
NAME    := $(notdir $(CURDIR))
TX       = $(REPO)/third_party/threadx
TX_PORT  = $(TX)/ports/cortex_m7/gnu
NX       = $(REPO)/third_party/netxduo
NX_PORT  = $(NX)/ports/cortex_m7/gnu

BOARD := h735dk
include $(REPO)/boards/$(BOARD)/board.mk

# NetX needs the ETH driver's header; the driver source lives in net/.
INCS = $(CMSIS) $(BOARD_INCS) -I$(REPO)/boards/$(BOARD) \
       -I$(TX_PORT)/inc -I$(TX)/common/inc \
       -I$(NX_PORT)/inc -I$(NX)/common/inc
CFLAGS  = $(MCU) -Os -g -ffreestanding -ffunction-sections -fdata-sections \
          $(BOARD_DEFS) $(INCS)
LDFLAGS = $(MCU) -T $(BOARD_LD_THREADX) -nostartfiles -Wl,--gc-sections \
          --specs=nano.specs --specs=nosys.specs -Wl,-Map=$(BUILD)/app.map

BUILD    = build

# --- ThreadX kernel archive (cortex_m7/gnu port + common), as in h735_threadx.
TX_A     = $(BUILD)/tx.a
TX_ASM   = $(wildcard $(TX_PORT)/src/*.S)
TX_C     = $(filter-out %/tx_misra.c,$(wildcard $(TX)/common/src/*.c))
TX_OBJ   = $(patsubst $(TX_PORT)/src/%.S,$(BUILD)/tx/%.o,$(TX_ASM)) \
           $(patsubst $(TX)/common/src/%.c,$(BUILD)/tx/%.o,$(TX_C))

# --- NetX Duo core archive (portable common/src; --gc-sections drops all the
# protocols P1 doesn't call — TCP/DHCP/DNS/IGMP land nowhere).
NX_A     = $(BUILD)/nx.a
NX_C     = $(wildcard $(NX)/common/src/*.c)
NX_OBJ   = $(patsubst $(NX)/common/src/%.c,$(BUILD)/nx/%.o,$(NX_C))

# board bring-up (crt0/vectors/systick + board.c), the ETH driver, the NetX glue,
# and this app.
BSP  = $(BOARD_BSP_THREADX) $(REPO)/boards/$(BOARD)/eth.c $(REPO)/net/nx_driver_stm32h7.c
APP  = main.c

all: $(BUILD)/$(NAME).bin

$(BUILD)/tx/%.o: $(TX_PORT)/src/%.S | $(BUILD)
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/tx/%.o: $(TX)/common/src/%.c | $(BUILD)
	@mkdir -p $(BUILD)/tx
	$(CC) $(CFLAGS) -c $< -o $@
$(TX_A): $(TX_OBJ)
	$(AR) -rc $@ $^

$(BUILD)/nx/%.o: $(NX)/common/src/%.c | $(BUILD)
	@mkdir -p $(BUILD)/nx
	$(CC) $(CFLAGS) -c $< -o $@
$(NX_A): $(NX_OBJ)
	$(AR) -rc $@ $^

# --start-group: NetX (nx.a) calls back into ThreadX (tx.a), so the two archives
# have interleaved cross-references — let ld resolve them as a group, not left-to-right.
$(BUILD)/$(NAME).elf: $(APP) $(BSP) $(TX_A) $(NX_A) $(BOARD_LD_THREADX) | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(APP) $(BSP) -Wl,--start-group $(TX_A) $(NX_A) -Wl,--end-group -o $@
	$(SIZE) $@

$(BUILD)/$(NAME).bin: $(BUILD)/$(NAME).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $(BUILD)

flash: $(BUILD)/$(NAME).bin
	st-flash $(if $(H735),--serial $(H735),) write $(BUILD)/$(NAME).bin 0x08000000
	st-flash $(if $(H735),--serial $(H735),) reset

gdb: $(BUILD)/$(NAME).elf
	$(GDB) $< -ex "target extended-remote :3333" -ex "load" -ex "break main" -ex "continue"

clean:
	rm -rf $(BUILD)

.PHONY: all flash gdb clean
.DELETE_ON_ERROR:
