V ?= v
REPO := .
# every repo tool a target runs is built once into bin/ (tools/tools.mk), never `v run` (#333)
include tools/tools.mk

.PHONY: example run-example list check deps deps-cmsis deps-lvgl trace trace-check coverage coverage-check lint vcan clean demo demo-threadx bench v-pin unit

# ---- Examples ---------------------------------------------------------------
# Each example is a self-contained app under examples/<NAME>/ with its own
# ecu.toml (+ optional bus.dbc). `make example NAME=<name>` generates all its
# code from config and compiles it.
# Each example is self-contained (examples/<name>/Makefile). These just delegate,
# so `make example NAME=overspeed` == `cd examples/overspeed && make all`.
# NAME is the root's parameter, not the example's: kept off the sub-make's command line, where it
# would override every Makefile's own NAME below it (a system's nodes each set theirs). Every other
# command-line override still passes through.
example: MAKEOVERRIDES := $(filter-out NAME=%,$(MAKEOVERRIDES))
example:
	@test -n "$(NAME)" || { echo "usage: make example NAME=<dir under examples/>"; exit 1; }
	$(MAKE) -C examples/$(NAME) all

run-example:
	@test -n "$(NAME)" || { echo "usage: make run-example NAME=<dir under examples/>"; exit 1; }
	$(MAKE) -C examples/$(NAME) run

list:
	@for d in examples/*/; do if [ -f "$$d/Makefile" ]; then basename "$$d"; fi; done

# one repo tool by name: `make tool-mkimage` builds bin/.tool-mkimage if it is not current
# (tools/tools.mk's targets are absolute paths, so `make bin/.tool-x` names no rule)
tool-%: $(TOOL_DIR)/.tool-% ;

# which V does CI use, and is it the one you are building with? advisory, never fails.
v-pin:
	@./scripts/v_pin.sh "$(V)"

# Validate every example's ecu.toml (and the loom2v test fixtures') against the schema (allowed/required/typed keys, the
# cross-field rules, and the nested-comment TOML-parser trap). Each example's `make gen` also
# runs this first, so a bad config fails before codegen; this checks them all at once. And the
# configuration reference and the editors' JSON Schemas must be what tools/cfgschema generates
# now (`make config-docs` rewrites them).
check: $(TOOL_ecucheck) $(TOOL_cfgdoc)
	@rc=0; for d in examples/*/ tools/loom2v/testdata/*/; do \
	  if [ -f "$$d/ecu.toml" ]; then $(TOOL_ecucheck) "$$d/ecu.toml" || rc=1; fi; \
	done; $(TOOL_cfgdoc) --check || rc=1; exit $$rc

# docs/config-reference.md and schema/*.schema.json, from the ONE schema (tools/cfgschema)
.PHONY: config-docs
config-docs: $(TOOL_cfgdoc)
	$(TOOL_cfgdoc)

# ---- Device (cross-compile) deps --------------------------------------------
# CMSIS register-map headers for the bare-metal STM32H7 examples (no HAL, no Cube).
# Header-only, gitignored under third_party/; needed ONLY by examples/h735_* cross
# builds — the host/sim build never touches them. Include paths for an example:
#   -Ithird_party/cmsis_device_h7/Include -Ithird_party/cmsis_core/CMSIS/Core/Include -DSTM32H735xx
# Just the CMSIS headers — everything a BARE-METAL image needs. Split out so CI can gate the
# bare-metal cross builds without cloning ThreadX and NetX Duo (minutes, and full clones because
# both are checked out at a pin).
# Pinned too: tools/vectab/vectab_test.v (a host unit test) checks the vector tables against the
# device headers' IRQn_Type, so an upstream header change must not fail an unrelated PR (#360).
CMSIS_DEVICE_H7_PIN ?= 81db1ec63cdc191fae1565b772da3ea5aa29a683
CMSIS_CORE_PIN      ?= afc5ca6af0a49232fde7eb4548dd0962d119ce14
deps-cmsis:
	@mkdir -p third_party
	@[ -d third_party/cmsis_device_h7 ] || git clone -q --depth 1 https://github.com/STMicroelectronics/cmsis_device_h7 third_party/cmsis_device_h7
	@cd third_party/cmsis_device_h7 && git checkout -q $(CMSIS_DEVICE_H7_PIN) 2>/dev/null || (git fetch -q --depth 1 origin $(CMSIS_DEVICE_H7_PIN) && git checkout -q $(CMSIS_DEVICE_H7_PIN))
	@[ -d third_party/cmsis_core ]       || git clone -q --depth 1 https://github.com/STMicroelectronics/cmsis_core       third_party/cmsis_core
	@cd third_party/cmsis_core && git checkout -q $(CMSIS_CORE_PIN) 2>/dev/null || (git fetch -q --depth 1 origin $(CMSIS_CORE_PIN) && git checkout -q $(CMSIS_CORE_PIN))
	@echo "CMSIS headers ready under third_party/ (bare-metal cross builds)"

# LVGL: the graphics library a [display] node's display thread runs (docs/display.md; today
# sysnode). OPTIONAL — not part of `deps`; only a display node needs it. Pinned to the v9.6.0 tag's
# commit and fetched sparse and blob-less: the library's sources and headers, not its hundreds of
# MB of docs, demos and tests.
LVGL_PIN ?= 80ca777e37a2b176770726a02e07a6fb79ef0b39
deps-lvgl:
	@mkdir -p third_party/lvgl
	@cd third_party/lvgl && [ -d .git ] || git init -q
	@cd third_party/lvgl && git sparse-checkout set --cone src include
	@cd third_party/lvgl && [ "$$(git rev-parse -q --verify HEAD 2>/dev/null)" = "$(LVGL_PIN)" ] || \
	  { git fetch -q --depth 1 --filter=blob:none https://github.com/lvgl/lvgl $(LVGL_PIN) && git checkout -q FETCH_HEAD; }
	@echo "LVGL ($(LVGL_PIN)) ready under third_party/lvgl ([display] nodes)"

deps: deps-cmsis
	@[ -d third_party/threadx/.git ]     || git clone https://github.com/eclipse-threadx/threadx third_party/threadx
	@cd third_party/threadx && git checkout -q $(THREADX_PIN) 2>/dev/null || (git fetch --quiet origin && git checkout -q $(THREADX_PIN))
	@[ -d third_party/netxduo/.git ]     || git clone https://github.com/eclipse-threadx/netxduo third_party/netxduo
	@cd third_party/netxduo && git checkout -q $(NETXDUO_PIN) 2>/dev/null || (git fetch --quiet origin && git checkout -q $(NETXDUO_PIN))
	@echo "CMSIS headers + ThreadX ($(THREADX_PIN)) + NetX Duo ($(NETXDUO_PIN)) ready under third_party/ (device cross-builds only)"

# ThreadX is pinned so the M7 kernel + execution-change hooks are reproducible across machines.
THREADX_PIN ?= 44d7c95c582d415c4ad84527180b29c93c3bf664
# NetX Duo (TCP/IP over Ethernet, docs/net.md) — ThreadX-native, packet-pool
# (no heap). Cortex-M7/GNU port matches the H735. Needed ONLY by the h735dk net build.
NETXDUO_PIN ?= 473d192822babbd831dc5907b9e279b340a3925b

# ---- Backend harness (POSIX / ThreadX), self-contained ----------------------
demo:
	$(V) -cc $(HOST_CC) -gc none -o blobly_demo cmd/threadx_demo
	./blobly_demo

THREADX ?=
TX_PORT = $(THREADX)/ports/linux/gnu
demo-threadx:
	@test -n "$(THREADX)" || { echo "set THREADX=/path/to/threadx (ports/linux/gnu/example_build/tx.a built)"; exit 1; }
	$(V) -cc $(HOST_CC) -d threadx -gc none \
	  -cflags "-DBLOBLY_THREADX -D_GNU_SOURCE -DTX_LINUX_MULTI_CORE -DTX_ENABLE_EVENT_TRACE -DTX_LINUX_DEBUG_ENABLE -I$(THREADX)/common/inc -I$(TX_PORT)/inc" \
	  -ldflags "$(TX_PORT)/example_build/tx.a -lrt" \
	  -o blobly_demo_threadx cmd/threadx_demo
	./blobly_demo_threadx

# ---- Requirement traceability ----------------------------------------------
# Generate docs/traceability.md from requirements/*.toml + verification links
# (`@verifies` tags in tests; requirements/verifications.toml for analysis/review).
trace: $(TOOL_trace)
	$(TOOL_trace)

# CI gate: nonzero exit if any requirement's linked verification FAILED.
trace-check: $(TOOL_trace)
	$(TOOL_trace) --check

# ---- Unit coverage ----------------------------------------------------------
# Statement coverage of the image code (tools/cover's scope) from the host unit tests, per file
# by its OWN module's tests and by any test, into docs/coverage.md. The file is a ratchet: CI
# fails when it is stale, so a file whose coverage drops shows that drop in the PR's diff, and
# coverage-check fails outright on a drop not yet recorded.
COVER_DIRS := comm driver ecu loom nvm wdg bcrypto boot
COVER_RUN = d=$$(mktemp -d) && trap 'rm -rf "$$d"' EXIT && \
	VJOBS=$${VJOBS:-$$(nproc)} $(V) -cc $(HOST_CC) -nocache -enable-globals -no-skip-unused -coverage "$$d" test $(COVER_DIRS) && \
	$(TOOL_cover) "$$d"
coverage: $(TOOL_cover)
	@$(COVER_RUN)
coverage-check: $(TOOL_cover)
	@$(COVER_RUN) --check

# System-level validation (docs/multi-node.md): the cross-node checks over a
# system.toml — single-writer per bus, identity uniqueness, NM cluster
# coherence, routes. The build gate for a system of ECUs, as `check` is per node.
# Override with SYSTEM=path/to/system.toml.
SYSTEM ?= examples/system_bench/system.toml
# The tools the system checks run per node (and syscheck's sysgen run), built by tools.mk and
# handed over through BLOB_TOOL_DIR (tools/sysmodel tool_dir_env): as prerequisites they are
# current, and the checks run them instead of compiling their own copies each run.
SYSTEM_GATE_TOOLS = $(TOOL_sysgen) $(TOOL_ecucheck) $(TOOL_loom2v) $(TOOL_dbcmerge)
SYSTEM_TOOLS_ENV = BLOB_TOOL_DIR=$(TOOL_DIR)
.PHONY: syscheck gen-system
syscheck: $(TOOL_syscheck) $(SYSTEM_GATE_TOOLS)
	$(SYSTEM_TOOLS_ENV) $(TOOL_syscheck) $(SYSTEM)

# Generate a complete ecu.toml per node from a DISSOLVED system.toml (P1b): the
# cross-node signals declared once + each node's authored internals -> gen-<node>.toml,
# each gated by ecucheck. docs/multi-node.md. Override with SYSTEM=.
gen-system: $(TOOL_sysgen) $(SYSTEM_GATE_TOOLS)
	$(SYSTEM_TOOLS_ENV) $(TOOL_sysgen) $(SYSTEM)

# ---- Misc -------------------------------------------------------------------
lint:
	./scripts/lint_noalloc.sh

# Performance benchmarks (one per family below — the echo lines are the list).
bench: $(TOOL_ioc_bench) $(TOOL_ioc_bench_mp) $(TOOL_loom_bench) $(TOOL_bulk_bench) $(TOOL_load_bench)
	@echo '== IOC transport, cross-thread (2 pinned cores) =='
	$(TOOL_ioc_bench)
	@echo '== IOC transport, cross-process AMP (fork + MAP_SHARED) =='
	$(TOOL_ioc_bench_mp)
	@echo '== Loom scheduler dispatch overhead =='
	$(TOOL_loom_bench)
	@echo '== Bulk ring throughput/latency vs ISO-TP (fork + MAP_SHARED) =='
	$(TOOL_bulk_bench)
	@echo '== System load: 4 cores, 8 CAN buses on core0, 50 FBs/core =='
	$(TOOL_load_bench)

# Real-stack scale benchmark: build the generated `scale` example (4 cores, 8 CAN
# buses, 200 FBs), run it on vcan0..7 with traffic, report per-core CPU + RAM.
# Needs `sudo make vcan` first.
bench-scale:
	cd examples/scale && $(MAKE) all
	./scripts/scale-bench.sh

# The host unit suite, as CI's host job runs it. V3's test runner allows one parallel job
# per 8 GB of memory (three on 32 GB) while a compile here peaks near 1 GB, so the suite runs
# one job per core unless VJOBS says otherwise. With HOST_CC (tools/tools.mk), not V's default
# tcc: the host OSAL's atomics (osal/osal_native.c) do not link under tcc, whose runtime forms are
# not atomic against each other anyway, so V redid those builds with cc behind a warning.
# -nocache: V3's module cache, with -cc named, emits a builtin module cc cannot compile.
UNIT_DIRS := comm driver tools ecu loom nvm wdg bcrypto boot
unit:
	VJOBS=$${VJOBS:-$$(nproc)} v -cc $(HOST_CC) -nocache -enable-globals test $(UNIT_DIRS)

# On-target regression tests — the "special tests run on target" group. Each
# bench_test.sh flashes its image to the attached board and asserts the
# driver behaviour over SWD (no scope, no manual wiring). Requires the board(s) on
# the bench; a script exits 2 (SKIP) when its board is absent, so a partial bench
# still passes for what IS attached. `BLOB_HWTEST=1 make trace` records the results
# into the h755/target column of docs/traceability.md.
#
# The glob covers examples/*/nodes/*/ too: a SYSTEM example's nodes are standalone build
# dirs with no Makefile above them, so `examples/*/` alone never reached domain's test —
# the same blind spot the CI example loop had to fix (codex #209 r2).
hwtest:
	@rc=0; n=0; for t in examples/*/bench_test.sh examples/*/nodes/*/bench_test.sh; do \
	  [ -x "$$t" ] || continue; n=1; echo "== $$t =="; \
	  "$$t" --flash; ec=$$?; \
	  case $$ec in 0) ;; 2) echo "  (skipped)";; *) echo "  (FAILED, exit $$ec)"; rc=1;; esac; \
	done; [ $$n = 1 ] || echo "no examples/*/bench_test.sh found"; exit $$rc

.PHONY: bench bench-scale hwtest

vcan:
	./scripts/setup_vcan.sh

clean:
	rm -rf bin blobly_demo blobly_demo_threadx examples/*/bin
