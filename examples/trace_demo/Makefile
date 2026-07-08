# Single-core handler-tracing demo — fully generated from ecu.toml (loom2v). The generation +
# build + clean rules are shared in examples/common.mk (so this example runs the identical
# pipeline as the others); only the trace-specific vcan bring-up + watch helpers are here.
# Sim-first: `make vcan` once, then `make run` on vcan0. blobly_net decodes the fixed
# observability protocol natively from gen/trace-manifest.csv (its `# trace frames` rows).
REPO ?= ../..
include $(REPO)/examples/common.mk

# bring up the virtual bus, then run + watch the HandlerStat frames
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

watch:
	candump vcan0,7E4:7FF

.PHONY: vcan watch
