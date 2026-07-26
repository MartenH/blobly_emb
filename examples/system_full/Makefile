# system_full — 3-ECU multi-node benchmark & integration test system (2 buses).
#
#   sysnode (H735-DK) : Central Gateway, compute<->edge router  [ThreadX, boards/h735dk]
#   domain  (H755-ZI) : Powertrain & Dynamics (compute)         [ThreadX, boards/h755zi]
#   zone_a  (H723)    : Front Zone ECU (edge)                   [ThreadX, boards/h723]
#
# Usage:
#   make syscheck          # validate system-wide invariants and signal routes
#   make gen               # sysgen -> gen-<node>.toml for all 3 nodes
#   make nodes             # cross-build all 3 ThreadX images (needs arm-none-eabi + make -C ../.. deps)
#   make all               # gen + syscheck + nodes
#
# Every node — including the gateway — is a real ThreadX image generated from system.toml.
# sysnode's comm thread owns both FDCAN buses (compute=FDCAN1, edge=FDCAN2) and forwards the
# 3 resolved routes on target (raw copy + id remap). Both buses come out on the H735-DK's own
# transceivers, so blobly_net can tap both. Driving edge on silicon needs the h735dk board to
# mux the FDCAN2 pins (a bench step); the image builds and its routing runs on host vcan.

NODES := sysnode domain zone_a

all: gen syscheck nodes

gen:
	$(MAKE) -C ../.. gen-system SYSTEM=examples/system_full/system.toml

syscheck:
	$(MAKE) -C ../.. syscheck SYSTEM=examples/system_full/system.toml

# cross-build every node's ThreadX image (requires the arm toolchain + `make -C ../.. deps`)
nodes: gen
	@for n in $(NODES); do echo "== building $$n"; $(MAKE) -C nodes/$$n all || exit 1; done

clean:
	@for n in $(NODES); do $(MAKE) -C nodes/$$n clean 2>/dev/null || true; done

.PHONY: all gen syscheck nodes clean
