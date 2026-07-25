V    ?= v
REPO  = ../../../..
SYSDIR= $(REPO)/examples/system_full
NAME := sysnode
GW   := examples/system_full/nodes/sysnode

all: gen build

gen: gen/.stamp
gen/.stamp: $(SYSDIR)/gen-$(NAME).toml $(wildcard app/*.v)
	@mkdir -p gen ports sig bin
	cd $(REPO) && tools/dbcmerge/dbcmerge $(GW)/gen/merged.dbc examples/system_full/compute.dbc examples/system_full/edge.dbc examples/system_full/body.dbc
	cd $(REPO) && tools/dbc2cfg/dbc2cfg $(GW)/gen/merged.dbc $(GW)/gen/dbc_gen.v
	cd $(REPO) && tools/cfg2v/cfg2v examples/system_full/gen-sysnode.toml $(GW)/gen/ecu_gen.v
	cd $(REPO) && tools/loom2v/loom2v examples/system_full/gen-$(NAME).toml $(GW)/gen/merged.dbc \
	  $(GW)/sig/signals_gen.v $(GW)/ports/ports_gen.v $(GW)/gen/loom_gen.v $(GW)/gen/trace-manifest.csv
	@touch gen/.stamp

build: gen
	@mkdir -p bin
	cd $(REPO) && $(V) -gc none -path "@vlib|@vmodules|.|$(GW)" -o $(GW)/bin/sysnode $(GW)

run: build
	./bin/sysnode vcan0 vcan1 vcan2

clean:
	rm -rf gen ports sig bin

.PHONY: all gen build run clean
.DELETE_ON_ERROR:
