V      ?= v
VFLAGS ?=
BIN    := blobly_emb

.PHONY: build run lint vcan clean demo demo-threadx gen

build:
	$(V) $(VFLAGS) -o $(BIN) .

# Regenerate all config-derived V from config/ (DBC codec + ecu.toml tables).
gen:
	$(V) -path "@vlib|@vmodules|tools" run tools/dbc2cfg/gen.v config/cantester.dbc comm/com/dbc_gen.v
	$(V) run tools/cfg2v/gen.v config/ecu.toml gen/ecu_gen.v
	$(V) run tools/loom2v/gen.v config/ecu.toml gen/loom_gen.v

run: build
	./$(BIN) vcan0

# The SpeedMonitor demo (real Loom + app) on the POSIX OSAL backend.
demo:
	$(V) -gc none -o blobly_demo cmd/threadx_demo
	./blobly_demo

# Same demo on the ThreadX OSAL backend. Needs a built ThreadX Linux library:
#   git clone --depth 1 https://github.com/eclipse-threadx/threadx
#   ( cd threadx/ports/linux/gnu/example_build && make tx.a ARCH64=1 )
#   make demo-threadx THREADX=$PWD/threadx
THREADX ?=
TX_PORT  = $(THREADX)/ports/linux/gnu
demo-threadx:
	@test -n "$(THREADX)" || { echo "set THREADX=/path/to/threadx (with ports/linux/gnu/example_build/tx.a built)"; exit 1; }
	$(V) -d threadx -gc none \
	  -cflags "-DBLOBLY_THREADX -D_GNU_SOURCE -DTX_LINUX_MULTI_CORE -DTX_ENABLE_EVENT_TRACE -DTX_LINUX_DEBUG_ENABLE -I$(THREADX)/common/inc -I$(TX_PORT)/inc" \
	  -ldflags "$(TX_PORT)/example_build/tx.a -lrt" \
	  -o blobly_demo_threadx cmd/threadx_demo
	./blobly_demo_threadx

# Static no-dynamic-allocation house-style check for app/ and comm/.
lint:
	./scripts/lint_noalloc.sh

# Bring up a virtual CAN interface on the host (needs sudo).
vcan:
	./scripts/setup_vcan.sh

clean:
	rm -f $(BIN) blobly_demo blobly_demo_threadx
