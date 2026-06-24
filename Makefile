V      ?= v
VFLAGS ?=
BIN    := blobly_emb

.PHONY: build run lint vcan clean

build:
	$(V) $(VFLAGS) -o $(BIN) .

run: build
	./$(BIN) vcan0

# Static no-dynamic-allocation house-style check for app/ and comm/.
lint:
	./scripts/lint_noalloc.sh

# Bring up a virtual CAN interface on the host (needs sudo).
vcan:
	./scripts/setup_vcan.sh

clean:
	rm -f $(BIN)
