# boot_sim — the bootloader's programming session on a virtual bus (no gen step:
# the bootloader is config-less by design; its parameters are link-time constants).
REPO ?= ../..
V    ?= v

.PHONY: all build run vcan clean
all: build

build:
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|.|examples/boot_sim" \
	  -o examples/boot_sim/bin/boot_sim examples/boot_sim/main.v

run: build
	./bin/boot_sim vcan0

vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

clean:
	rm -rf bin
