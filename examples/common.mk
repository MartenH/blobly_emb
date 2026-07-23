# Shared rules for a freestanding host example: generate code from this example's config
# (ecu.toml + optional bus.dbc) with the repo tools, then build. One place so the generation
# pipeline can't drift between examples. Include after setting REPO:
#
#     REPO ?= ../..
#     include $(REPO)/examples/common.mk
#
# The example dir supplies ecu.toml (+ optional bus.dbc, app/). An example with extra targets
# (e.g. a vcan bring-up, a cross-compile) adds them after the include.
V          ?= v
NAME       := $(notdir $(CURDIR))
BLOBLY_NET ?=

.PHONY: all gen build run test clean
all: gen build

# Generate — the SAME steps for every example, so a change to [bus].fd, a new signal, or the
# trace config is reflected in the tree.
# `v run <tool>` derives the compiled binary's path from the TOOL's source path, so two examples
# generating at the same time write and exec the SAME file — one gets `Text file busy` (ETXTBSY)
# or `No such file or directory` mid-exec. That is why `v test examples` fails randomly while each
# example passes alone. Compiling each tool to a path under THIS example's bin/ removes the shared
# name; V's object cache is still shared, so it costs nothing.
gen:
	@mkdir -p gen ports sig bin
	@if [ -f bus.dbc ]; then $(V) -o bin/.tool-dbc2cfg $(REPO)/tools/dbc2cfg/gen.v && ./bin/.tool-dbc2cfg bus.dbc gen/dbc_gen.v; fi
	$(V) -o bin/.tool-ecucheck $(REPO)/tools/ecucheck/gen.v && ./bin/.tool-ecucheck ecu.toml
	$(V) -o bin/.tool-cfg2v $(REPO)/tools/cfg2v/gen.v && ./bin/.tool-cfg2v ecu.toml gen/ecu_gen.v
	$(V) -o bin/.tool-loom2v $(REPO)/tools/loom2v && ./bin/.tool-loom2v ecu.toml bus.dbc sig/signals_gen.v ports/ports_gen.v gen/loom_gen.v gen/trace-manifest.csv
	$(V) -o bin/.tool-sigmap $(REPO)/tools/sigmap/gen.v && ./bin/.tool-sigmap ecu.toml signal-map.md

# Build: local modules (sig/app/ports/gen) + the repo framework, via V's -path.
build:
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|.|examples/$(NAME)" -o examples/$(NAME)/bin/app examples/$(NAME)

# depend on `all` (gen + build), not just build, so a config edit is regenerated before running.
# RUN_IFACE is the interface arg(s); a multi-bus example (e.g. trace_comm) overrides it with its
# own split (trace bus first) instead of overriding the whole recipe.
RUN_IFACE ?= vcan0
run: all
	./bin/app $(RUN_IFACE)

# Integration test: run on vcan0 and drive/assert with blobly_net's headless Lua runner
# (needs BLOBLY_NET=/path/to/blobly_net + vcan0 up).
test: build
	BLOBLY_NET=$(BLOBLY_NET) bash $(REPO)/scripts/integration-test.sh .

# gen/ports/sig are generated but committed (browsable without building), so clean only removes
# build outputs — never tracked sources.
clean:
	rm -rf bin
