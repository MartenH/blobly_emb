# tester — the system_full tester as a HOST node (no cross toolchain): generated from the
# dissolved gen-tester.toml + compute.dbc like any leaf, built with V, run on vcan0. On the
# bench blobly_net simulates this node instead (system_full.blobnet `simulation: tester`).
V     ?= v
REPO   = ../../../..
NODE   = examples/system_full/nodes/tester
SYS    = examples/system_full

.PHONY: all gen build run clean
all: gen build

gen:
	@mkdir -p gen ports sig bin
	$(MAKE) -C $(REPO) gen-system SYSTEM=$(SYS)/system.toml
	cd $(REPO) && $(V) run tools/dbc2cfg/gen.v $(SYS)/compute.dbc $(NODE)/gen/dbc_gen.v
	cd $(REPO) && $(V) run tools/cfg2v/gen.v $(SYS)/gen-tester.toml $(NODE)/gen/ecu_gen.v
	cd $(REPO) && $(V) run tools/loom2v $(SYS)/gen-tester.toml $(SYS)/compute.dbc \
	  $(NODE)/sig/signals_gen.v $(NODE)/ports/ports_gen.v $(NODE)/gen/loom_gen.v $(NODE)/gen/trace-manifest.csv

build: gen
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|.|$(NODE)" -o $(NODE)/bin/app $(NODE)

run: build
	./bin/app vcan0

clean:
	rm -rf gen ports sig bin
