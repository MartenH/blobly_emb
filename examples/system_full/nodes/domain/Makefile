REPO ?= ../../../..
NAME := domain

all: gen

gen:
	$(MAKE) -C $(REPO) gen-system SYSTEM=examples/system_full/system.toml

.PHONY: all gen
