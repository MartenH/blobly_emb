# P4 dev harness (host / vcan): multi-core dump-in-one-command + the thread-switch
# swimlane. Hand-wired pending the loom2v core_mask fan-out — it exists to develop +
# verify the core_mask control, per-core self-describing ISO-TP blocks, and the
# thread-switch record kind on WSL before that path is generated.
REPO ?= ../..
V    ?= v
BIN   = bin/trace_multicore

all: $(BIN)

$(BIN): main.v
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|." -o examples/trace_multicore/$(BIN) examples/trace_multicore/main.v

# bring up the virtual bus, then run + watch the per-core TraceRsp replies
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

run: all
	./$(BIN) vcan0

watch:
	candump vcan0,7E3:7FF

clean:
	rm -rf bin

.PHONY: all vcan run watch clean
