# Two-core handler-tracing demo — fully generated from ecu.toml (loom2v P3a). The generation +
# build + clean rules are shared in examples/common.mk (identical pipeline to the other
# examples); only the trace-specific vcan bring-up + watch helpers are here. Sim-first: `make
# vcan` once, then `make run` on vcan0. blobly_net decodes the fixed observability protocol
# natively from gen/trace-manifest.csv (its `# trace frames` + both cores' handler rows).
REPO ?= ../..
include $(REPO)/examples/common.mk

# bring up the virtual bus, then run + watch the per-core TraceRsp replies (b7 = core)
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

watch:
	candump vcan0,7E3:7FF

.PHONY: vcan watch
