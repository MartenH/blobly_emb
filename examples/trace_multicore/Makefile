# Two-core handler-tracing demo — generated from ecu.toml (loom2v P3a). The generation +
# build + clean rules are shared in examples/common.mk (identical pipeline to the other
# examples); only the trace-specific vcan bring-up + watch helpers are here. Sim-first: `make
# vcan` once, then `make run` on vcan0.
#
# blobly_net decodes the fixed observability protocol natively from gen/trace-manifest.csv — both
# cores' handler + thread rows AND the `# trace frames` rows (cmd/rsp/record/dump_fc).
#
# NOTE for `watch`: a command selecting BOTH cores answers with ONE TraceRsp, the owner's. The
# dump block header carries only (core, count, more) — no state — so core 1's STATE is read by
# addressing it alone (mask 0x0002), which answers with the satellite's own TraceRsp. Two
# responses per both-cores stop/dump is not the success criterion; two dump BLOCKS is.
REPO ?= ../..
include $(REPO)/examples/common.mk

# bring up the virtual bus, then run + watch the per-core TraceRsp replies (b7 = core)
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

watch:
	candump vcan0,7E3:7FF

.PHONY: vcan watch
