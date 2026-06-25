# Freestanding example.  Build it with:   make all
# It needs only a path to the main repo (REPO) — for the generators in tools/ and
# the shared framework (osal/loom/driver). Everything else lives in this folder.
REPO ?= ../..
V    ?= v
NAME := $(notdir $(CURDIR))

CANTESTER ?=

.PHONY: all gen build run test clean
all: gen build

# Generate code from this example's config (ecu.toml + bus.dbc) using repo tools.
gen:
	@mkdir -p gen ports sig bin
	@if [ -f bus.dbc ]; then $(V) run $(REPO)/tools/dbc2cfg/gen.v bus.dbc gen/dbc_gen.v; fi
	$(V) run $(REPO)/tools/cfg2v/gen.v  ecu.toml gen/ecu_gen.v
	$(V) run $(REPO)/tools/loom2v/gen.v ecu.toml sig/signals_gen.v ports/ports_gen.v gen/loom_gen.v
	$(V) run $(REPO)/tools/sigmap/gen.v ecu.toml signal-map.md

# Build: local modules (sig/app/ports/gen) + the repo framework, via V's -path.
build:
	@mkdir -p bin
	cd $(REPO) && $(V) -path "@vlib|@vmodules|.|examples/$(NAME)" -o examples/$(NAME)/bin/app examples/$(NAME)

run: build
	./bin/app vcan0

# Integration test: run the app on vcan0 and drive/assert it with cantester_v's
# headless Lua runner (needs CANTESTER=/path/to/cantester_v + vcan0 up).
test: build
	CANTESTER=$(CANTESTER) bash $(REPO)/scripts/integration-test.sh .

clean:
	rm -rf bin
