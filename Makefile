V ?= v

.PHONY: example run-example list lint vcan clean demo demo-threadx

# ---- Examples ---------------------------------------------------------------
# Each example is a self-contained app under examples/<NAME>/ with its own
# ecu.toml (+ optional bus.dbc). `make example NAME=<name>` generates all its
# code from config and compiles it.
EX = examples/$(NAME)

example:
	@test -n "$(NAME)" || { echo "usage: make example NAME=<dir under examples/>"; exit 1; }
	@test -d "$(EX)" || { echo "no such example: $(EX)"; exit 1; }
	@if [ -f "$(EX)/bus.dbc" ]; then \
		$(V) -path "@vlib|@vmodules|tools" run tools/dbc2cfg/gen.v "$(EX)/bus.dbc" "$(EX)/gen_dbc.v"; \
	fi
	$(V) run tools/cfg2v/gen.v "$(EX)/ecu.toml" "$(EX)/gen_ecu.v"
	$(V) run tools/loom2v/gen.v "$(EX)/ecu.toml" "$(EX)/gen_ports.v" "$(EX)/gen_loom.v"
	$(V) run tools/sigmap/gen.v "$(EX)/ecu.toml" "$(EX)/signal-map.md"
	$(V) -o "$(EX)/app" "$(EX)"
	@echo "built $(EX)/app"

run-example: example
	./$(EX)/app vcan0

list:
	@ls -1 examples/

# ---- Backend harness (POSIX / ThreadX), self-contained ----------------------
demo:
	$(V) -gc none -o blobly_demo cmd/threadx_demo
	./blobly_demo

THREADX ?=
TX_PORT = $(THREADX)/ports/linux/gnu
demo-threadx:
	@test -n "$(THREADX)" || { echo "set THREADX=/path/to/threadx (ports/linux/gnu/example_build/tx.a built)"; exit 1; }
	$(V) -d threadx -gc none \
	  -cflags "-DBLOBLY_THREADX -D_GNU_SOURCE -DTX_LINUX_MULTI_CORE -DTX_ENABLE_EVENT_TRACE -DTX_LINUX_DEBUG_ENABLE -I$(THREADX)/common/inc -I$(TX_PORT)/inc" \
	  -ldflags "$(TX_PORT)/example_build/tx.a -lrt" \
	  -o blobly_demo_threadx cmd/threadx_demo
	./blobly_demo_threadx

# ---- Misc -------------------------------------------------------------------
lint:
	./scripts/lint_noalloc.sh

vcan:
	./scripts/setup_vcan.sh

clean:
	rm -f blobly_demo blobly_demo_threadx examples/*/app
