V ?= v

.PHONY: example run-example list deps trace trace-check lint vcan clean demo demo-threadx bench

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

# ---- Device (cross-compile) deps --------------------------------------------
# CMSIS register-map headers for the bare-metal STM32H7 examples (no HAL, no Cube).
# Header-only, gitignored under third_party/; needed ONLY by examples/h735_* cross
# builds — the host/sim build never touches them. Include paths for an example:
#   -Ithird_party/cmsis_device_h7/Include -Ithird_party/cmsis_core/CMSIS/Core/Include -DSTM32H735xx
deps:
	@mkdir -p third_party
	@[ -d third_party/cmsis_device_h7 ] || git clone --depth 1 https://github.com/STMicroelectronics/cmsis_device_h7 third_party/cmsis_device_h7
	@[ -d third_party/cmsis_core ]       || git clone --depth 1 https://github.com/STMicroelectronics/cmsis_core       third_party/cmsis_core
	@echo "CMSIS headers ready under third_party/ (device cross-builds only)"

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

.PHONY: bench bench-scale

vcan:
	./scripts/setup_vcan.sh

clean:
	rm -rf bin blobly_demo blobly_demo_threadx examples/*/bin
