# Comm-thread trace demo (P3b) — fully generated from ecu.toml (loom2v). Generation + build + clean
# come from examples/common.mk; only the vcan bring-up (TWO buses) + watch are here. Sim-first:
# `make vcan` once, then `make run`. blobly_net decodes the fixed protocol natively from
# gen/trace-manifest.csv (its `# threads` rows now include comm_can0).
REPO ?= ../..
include $(REPO)/examples/common.mk

# main.v reads arg1 as the TRACE bus, arg2 as the COM bus; the documented split is trace on vcan1,
# COM on vcan0. Set the shared RUN_IFACE knob (common.mk's `run` passes it to ./bin/app) rather than
# overriding the recipe — otherwise the default single vcan0 opens trace + COM on the same bus.
RUN_IFACE = vcan1 vcan0

# app bus (vcan0) + dedicated trace bus (vcan1)
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0
	sudo ip link add dev vcan1 type vcan 2>/dev/null || true
	sudo ip link set up vcan1

watch:
	candump vcan1,7E3:7FF

.PHONY: vcan watch
