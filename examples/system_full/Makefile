# system_full — 4-ECU multi-node benchmark & integration test system.
#
#   sysnode (H735-DK) : Central Gateway & Ethernet Edge     [host/sim gateway today]
#   domain  (H755-ZI) : Powertrain & Dynamics               [ThreadX, boards/h755zi]
#   zone_a  (H723 #1) : Front Zone ECU                       [ThreadX, boards/h723]
#   zone_b  (H723 #2) : Rear Body ECU                        [ThreadX, boards/h723]
#
# Usage:
#   make syscheck          # validate system-wide invariants and signal routes
#   make gen               # sysgen -> gen-<node>.toml for all 4 nodes
#   make nodes             # cross-build the 3 leaf ThreadX images (needs arm-none-eabi + make -C ../.. deps)
#   make all               # gen + syscheck + nodes
#
# sysnode is the 3-bus gateway: it runs as a host/sim image today (loom2v does not yet
# emit a multi-bus ThreadX comm owner — the "target multi-bus comm owner" roadmap item),
# so `make nodes` builds only the three single-bus leaf nodes on real silicon. Their
# generation is still driven entirely from system.toml.

LEAF := domain zone_a zone_b

all: gen syscheck nodes

gen:
	$(MAKE) -C ../.. gen-system SYSTEM=examples/system_full/system.toml

syscheck:
	$(MAKE) -C ../.. syscheck SYSTEM=examples/system_full/system.toml

# cross-build every leaf node's ThreadX image (requires the arm toolchain + `make -C ../.. deps`)
nodes: gen
	@for n in $(LEAF); do echo "== building $$n"; $(MAKE) -C nodes/$$n all || exit 1; done

clean:
	@for n in $(LEAF) sysnode; do $(MAKE) -C nodes/$$n clean 2>/dev/null || true; done

.PHONY: all gen syscheck nodes clean
