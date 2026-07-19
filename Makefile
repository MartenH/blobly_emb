V ?= v

.PHONY: example run-example list check deps trace trace-check lint vcan clean demo demo-threadx bench

# ---- Examples ---------------------------------------------------------------
# Each example is a self-contained app under examples/<NAME>/ with its own
# ecu.toml (+ optional bus.dbc). `make example NAME=<name>` generates all its
# code from config and compiles it.
# Each example is self-contained (examples/<name>/Makefile). These just delegate,
# so `make example NAME=overspeed` == `cd examples/overspeed && make all`.
example:
	@test -n "$(NAME)" || { echo "usage: make example NAME=<dir under examples/>"; exit 1; }
	$(MAKE) -C examples/$(NAME) all

run-example:
	@test -n "$(NAME)" || { echo "usage: make run-example NAME=<dir under examples/>"; exit 1; }
	$(MAKE) -C examples/$(NAME) run

list:
	@for d in examples/*/; do if [ -f "$$d/Makefile" ]; then basename "$$d"; fi; done

# Validate every example's ecu.toml against the schema (allowed/required/typed keys, the
# cross-field rules, and the nested-comment TOML-parser trap). Each example's `make gen` also
# runs this first, so a bad config fails before codegen; this checks them all at once.
check:
	@rc=0; for d in examples/*/; do \
	  if [ -f "$$d/ecu.toml" ]; then $(V) run tools/ecucheck/gen.v "$$d/ecu.toml" || rc=1; fi; \
	done; exit $$rc

# ---- Device (cross-compile) deps --------------------------------------------
# CMSIS register-map headers for the bare-metal STM32H7 examples (no HAL, no Cube).
# Header-only, gitignored under third_party/; needed ONLY by examples/h735_* cross
# builds — the host/sim build never touches them. Include paths for an example:
#   -Ithird_party/cmsis_device_h7/Include -Ithird_party/cmsis_core/CMSIS/Core/Include -DSTM32H735xx
deps:
	@mkdir -p third_party
	@[ -d third_party/cmsis_device_h7 ] || git clone --depth 1 https://github.com/STMicroelectronics/cmsis_device_h7 third_party/cmsis_device_h7
	@[ -d third_party/cmsis_core ]       || git clone --depth 1 https://github.com/STMicroelectronics/cmsis_core       third_party/cmsis_core
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

# ---- Requirement traceability ----------------------------------------------
# Generate docs/traceability.md from requirements/*.toml + verification links
# (`@verifies` tags in tests; requirements/verifications.toml for analysis/review).
trace:
	$(V) run tools/trace/gen.v

# CI gate: nonzero exit if any requirement's linked verification FAILED.
trace-check:
	$(V) run tools/trace/gen.v --check

# System-level validation (docs/multi-node.md): the cross-node checks over a
# system.toml — single-writer per bus, identity uniqueness, NM cluster
# coherence, routes. The build gate for a system of ECUs, as `check` is per node.
# Override with SYSTEM=path/to/system.toml.
SYSTEM ?= examples/system_bench/system.toml
.PHONY: syscheck gen-system
syscheck:
	$(V) -enable-globals run tools/syscheck $(SYSTEM)

# Generate a complete ecu.toml per node from a DISSOLVED system.toml (P1b): the
# cross-node signals declared once + each node's authored internals -> gen-<node>.toml,
# each gated by ecucheck. docs/multi-node.md. Override with SYSTEM=.
gen-system:
	$(V) -enable-globals run tools/sysgen $(SYSTEM)

# ---- Misc -------------------------------------------------------------------
lint:
	./scripts/lint_noalloc.sh

# Performance benchmarks: lock-free IOC transport (cross-thread + cross-process
# AMP) and the Loom scheduler dispatch overhead.
bench:
	@echo '== IOC transport, cross-thread (2 pinned cores) =='
	$(V) -prod run tools/ioc_bench/bench.v
	@echo '== IOC transport, cross-process AMP (fork + MAP_SHARED) =='
	$(V) -gc none run tools/ioc_bench_mp/bench.v
	@echo '== Loom scheduler dispatch overhead =='
	$(V) -prod run tools/loom_bench/bench.v
	@echo '== System load: 4 cores, 8 CAN buses on core0, 50 FBs/core =='
	$(V) -gc none run tools/load_bench/bench.v

# Real-stack scale benchmark: build the generated `scale` example (4 cores, 8 CAN
# buses, 200 FBs), run it on vcan0..7 with traffic, report per-core CPU + RAM.
# Needs `sudo make vcan` first.
bench-scale:
	cd examples/scale && $(MAKE) all
	./scripts/scale-bench.sh

# On-target regression tests — the "special tests run on target" group. Each
# examples/*/bench_test.sh flashes its image to the attached board and asserts the
# driver behaviour over SWD (no scope, no manual wiring). Requires the board(s) on
# the bench; a script exits 2 (SKIP) when its board is absent, so a partial bench
# still passes for what IS attached. `BLOB_HWTEST=1 make trace` records the results
# into the h755/target column of docs/traceability.md.
hwtest:
	@rc=0; n=0; for t in examples/*/bench_test.sh; do \
	  [ -x "$$t" ] || continue; n=1; echo "== $$t =="; \
	  "$$t" --flash; ec=$$?; [ $$ec = 1 ] && rc=1; \
	done; [ $$n = 1 ] || echo "no examples/*/bench_test.sh found"; exit $$rc

.PHONY: bench bench-scale hwtest

vcan:
	./scripts/setup_vcan.sh

clean:
	rm -rf bin blobly_demo blobly_demo_threadx examples/*/bin
