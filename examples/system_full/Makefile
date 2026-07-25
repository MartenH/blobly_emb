# system_full — 4-ECU multi-node benchmark & integration test system.
#
#   sysnode (H735-DK) : Central Gateway, 3-bus router      [ThreadX, boards/h735dk]
#   domain  (H755-ZI) : Powertrain & Dynamics              [ThreadX, boards/h755zi]
#   zone_a  (H723 #1) : Front Zone ECU                      [ThreadX, boards/h723]
#   zone_b  (H723 #2) : Rear Body ECU                       [ThreadX, boards/h723]
#
# Usage:
#   make syscheck          # validate system-wide invariants and signal routes
#   make gen               # sysgen -> gen-<node>.toml for all 4 nodes
#   make nodes             # cross-build all 4 ThreadX images (needs arm-none-eabi + make -C ../.. deps)
#   make all               # gen + syscheck + nodes
#
# Every node — including the gateway — is a real ThreadX image generated from system.toml.
# sysnode's comm thread owns all three FDCAN buses and forwards the 8 resolved routes on
# target (raw copy + id remap). Full 3-transceiver silicon on sysnode needs the h735dk board
# to mux FDCAN2/3 pins (a bench step); the image builds and its routing runs on host vcan.

NODES := sysnode domain zone_a zone_b

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
