# P1 handler-tracing dev harness (host / vcan). Hand-wired pending the loom2v
# HandlerStat emitter — it exists to develop + verify loom.run_profiled +
# telem.encode_handlerstat on WSL before that path is generated.
REPO ?= ../..
V    ?= v
BIN   = bin/trace_demo

all: $(BIN)

$(BIN): main.v
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|." -o examples/trace_demo/$(BIN) examples/trace_demo/main.v

# bring up the virtual bus, then run + watch the HandlerStat frames
vcan:
	sudo ip link add dev vcan0 type vcan 2>/dev/null || true
	sudo ip link set up vcan0

run: all
	./$(BIN) vcan0

watch:
	candump vcan0,7E4:7FF

clean:
	rm -rf bin

.PHONY: all vcan run watch clean
