# Single-core handler-tracing demo — fully generated from ecu.toml (loom2v). `make all`
# validates the config, generates the loom + trace wiring + manifest, then builds the tiny
# main.v. Sim-first: run on vcan0 and drive it from blobly_net (gen/trace-manifest.csv carries
# the trace frame ids; blobly_net decodes the fixed protocol natively — no generated DBC).
REPO ?= ../..
V    ?= v
NAME := $(notdir $(CURDIR))

.PHONY: all gen build run vcan watch clean
all: gen build

# Generate everything from this example's config. bus.dbc is empty (no bus signals) but
# satisfies loom2v's DBC argument.
gen:
	@mkdir -p gen ports sig bin
	$(V) run $(REPO)/tools/ecucheck/gen.v ecu.toml
	$(V) run $(REPO)/tools/loom2v/gen.v ecu.toml bus.dbc sig/signals_gen.v ports/ports_gen.v \
	  gen/loom_gen.v gen/trace-manifest.csv

# Build: local modules (gen/app/ports/sig) + the repo framework, via V's -path.
build:
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|.|examples/$(NAME)" -o examples/$(NAME)/bin/$(NAME) examples/$(NAME)

# bring up the virtual bus, then run + watch the HandlerStat frames
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

run: all
	./bin/$(NAME) vcan0

watch:
	candump vcan0,7E4:7FF

# only build outputs — gen/ports/sig are generated but committed (like the other examples), so
# `make clean` must not delete tracked sources and leave the checkout dirty / un-buildable.
clean:
	rm -rf bin

.PHONY: all gen build run vcan watch clean
