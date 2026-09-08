# Two-core handler-tracing demo — generated from ecu.toml (loom2v P3a). The generation +
# build + clean rules are shared in examples/common.mk (identical pipeline to the other
# examples); only the trace-specific vcan bring-up + watch helpers are here. Sim-first: `make
# vcan` once, then `make run` on vcan0.
#
# NOTE: `[trace]` is `enabled = false` today (#191 — loom2v generates the ring + dump for the
# single-partition host shape only, and rejects an enabled [trace] elsewhere rather than build a
# silent no-op). So gen/trace-manifest.csv carries both cores' handler + thread rows but NO
# `# trace frames` rows, and the `watch` target below sees no TraceRsp — nothing answers a dump
# until that generator wiring returns. See README.md.
REPO ?= ../..
include $(REPO)/examples/common.mk

# bring up the virtual bus, then run + watch the per-core TraceRsp replies (b7 = core)
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

watch:
	candump vcan0,7E3:7FF

.PHONY: vcan watch
