# system_full — 4-ECU multi-node benchmark & integration test system.
#
#   sysnode (H735-DK) : Central Gateway & Ethernet Edge
#   domain  (H755-ZI) : Dual-core Powertrain & Dynamics
#   zone_a  (H723 #1) : Front Zone ECU
#   zone_b  (H723 #2) : Rear Body ECU
#
# Usage:
#   make gen               # sysgen -> gen-<node>.toml for all 4 nodes
#   make syscheck          # validate system-wide invariants and signal routes

all: gen

gen:
	$(MAKE) -C ../.. gen-system SYSTEM=examples/system_full/system.toml

syscheck:
	$(MAKE) -C ../.. syscheck SYSTEM=examples/system_full/system.toml

.PHONY: all gen syscheck
