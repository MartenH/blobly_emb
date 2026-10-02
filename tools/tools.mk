# The ONE rule for running a repo tool from a Makefile: build it once, to a path of the including
# directory's own, then run the binary. Never `$(V) run tools/...`: `v run` derives its binary's
# path from the TOOL's source path, so two makes running one tool at once write and exec the SAME
# file, and one of them dies with `No such file or directory` or `Text file busy` (#313, #333).
# tools/loom2v/no_v_run_makefiles_test.v pins that no Makefile does.
#
# Include after setting REPO (the repo root, relative to the including Makefile):
#
#     REPO = ../..
#     include $(REPO)/tools/tools.mk
#
# then name $(TOOL_<name>) as a PREREQUISITE of the target whose recipe runs it, and run it by
# that same variable — an absolute path, so it still resolves after a `cd $(REPO)`:
#
#     gen/.stamp: ecu.toml $(TOOL_loom2v)
#     	cd $(REPO) && $(TOOL_loom2v) examples/x/ecu.toml ...
#
# A tool is rebuilt when any source compiled into it changes, vlib's included (so a new V rebuilds
# it) and the C a module pulls in beside its V (scripts/build_tool.sh writes that list beside it),
# when this file changes, and when it has no such list; a target depending on it is remade
# when it is. The binaries live in bin/ of the including directory, which `make clean` removes.
V ?= v

# name -> what V compiles: one file for a single-file program, the directory for a multi-file one
TOOL_SRC_cfg2v       := tools/cfg2v/gen.v
TOOL_SRC_dbc2cfg     := tools/dbc2cfg/gen.v
TOOL_SRC_dbcmerge    := tools/dbcmerge/gen.v
TOOL_SRC_ecucheck    := tools/ecucheck/gen.v
TOOL_SRC_loom2v      := tools/loom2v
TOOL_SRC_scale_gen   := tools/scale_gen/gen.v
TOOL_SRC_sigmap      := tools/sigmap/gen.v
TOOL_SRC_syscheck    := tools/syscheck
TOOL_SRC_sysgen      := tools/sysgen
TOOL_SRC_trace       := tools/trace/gen.v
TOOL_SRC_ioc_bench    := tools/ioc_bench/bench.v
TOOL_SRC_ioc_bench_mp := tools/ioc_bench_mp/bench.v
TOOL_SRC_loom_bench   := tools/loom_bench/bench.v
TOOL_SRC_bulk_bench   := tools/bulk_bench/bench.v
TOOL_SRC_load_bench   := tools/load_bench/bench.v

# the V flags a tool is compiled with, where it needs any
TOOL_FLAGS_syscheck     := -enable-globals
TOOL_FLAGS_sysgen       := -enable-globals
TOOL_FLAGS_ioc_bench    := -prod
TOOL_FLAGS_ioc_bench_mp := -gc none
TOOL_FLAGS_loom_bench   := -prod
TOOL_FLAGS_bulk_bench   := -prod -gc none
TOOL_FLAGS_load_bench   := -gc none

TOOL_REPO := $(abspath $(REPO))
TOOL_DIR  := $(CURDIR)/bin
TOOLS     := $(patsubst TOOL_SRC_%,%,$(filter TOOL_SRC_%,$(.VARIABLES)))
$(foreach t,$(TOOLS),$(eval TOOL_$(t) := $(TOOL_DIR)/.tool-$(t)))
# also rebuilt when this file changes (a tool's flags or source live here)
$(TOOL_DIR)/.tool-%: $(TOOL_REPO)/tools/tools.mk
	@test -n "$(TOOL_SRC_$*)" || { echo "tools.mk: no tool named '$*'"; exit 1; }
	V="$(V)" $(TOOL_REPO)/scripts/build_tool.sh $@ "$(TOOL_FLAGS_$*)" $(TOOL_REPO)/$(TOOL_SRC_$*)
# a dependency list is written by the build above, never made on its own
$(TOOL_DIR)/.tool-%.d: ;

# a tool with no dependency list has no record of what it was built from (a binary the old
# common.mk left in bin/), so it is rebuilt
.PHONY: tool-unrecorded
$(foreach t,$(TOOLS),$(if $(wildcard $(TOOL_DIR)/.tool-$(t).d),,$(eval $(TOOL_DIR)/.tool-$(t): tool-unrecorded)))

# the dependency lists hold explicit rules; keep them from taking the including Makefile's
# default goal (the first target it names after this include stays `all`)
TOOL_GOAL := $(.DEFAULT_GOAL)
-include $(wildcard $(TOOL_DIR)/.tool-*.d)
.DEFAULT_GOAL := $(TOOL_GOAL)
