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
# A tool is rebuilt when anything it was built from changes (the inputs are listed below, above
# the rule), and a target depending on it is remade when it is. The binaries live in bin/ of the
# including directory, which `make clean` removes.
V ?= v

# name -> what V compiles: one file for a single-file program, the directory for a multi-file one
TOOL_SRC_cfg2v       := tools/cfg2v/gen.v
TOOL_SRC_dbc2cfg     := tools/dbc2cfg/gen.v
TOOL_SRC_dbcmerge    := tools/dbcmerge/gen.v
TOOL_SRC_ecucheck    := tools/ecucheck/gen.v
TOOL_SRC_loom2v      := tools/loom2v
TOOL_SRC_mkimage     := tools/mkimage/gen.v
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

# Everything below declares explicit targets (the unrecorded-tool prerequisites, the dependency
# lists), and the first explicit target make reads becomes the default goal. Save the including
# Makefile's goal BEFORE any of them and restore it at the end, so it is unchanged: empty when
# the include comes before the Makefile's first target, which then takes it as before.
# tools/loom2v/no_v_run_makefiles_test.v asks make itself.
TOOL_GOAL := $(.DEFAULT_GOAL)

# The dependencies of a target V TRANSPILES — an image's generated C (app.c), the bootloader's
# (boot/boot.mk) — are what V compiled into it, from its own -dump-files, written by
# scripts/vdeps.sh: never a hand list of module directories, which went stale the day a generated
# image started importing one more (driver/doipnet). In the rule, V run from $(REPO):
#
#     $(BUILD)/app.c: main.v gen/.stamp | $(BUILD)
#     	cd $(REPO) && $(V) -freestanding ... $(call v_dump,$@) -o .../$(BUILD)/app.c .../main.v
#     	$(call v_deps,$@)
#     -include $(BUILD)/app.c.d
#
# scripts/app_deps_check.sh asks make that a module's edit remakes every image importing it.
v_dump = -dump-files $(CURDIR)/$(1).files
v_deps = VDEPS_BASE=$(TOOL_REPO) $(TOOL_REPO)/scripts/vdeps.sh $(1) $(1).files >$(1).d.tmp && mv -f $(1).d.tmp $(1).d

TOOL_REPO := $(abspath $(REPO))
TOOL_DIR  := $(CURDIR)/bin
TOOLS     := $(patsubst TOOL_SRC_%,%,$(filter TOOL_SRC_%,$(.VARIABLES)))
$(foreach t,$(TOOLS),$(eval TOOL_$(t) := $(TOOL_DIR)/.tool-$(t)))
# a source path is relative to the repo root, or absolute
tool_src = $(if $(filter /%,$(TOOL_SRC_$(1))),$(TOOL_SRC_$(1)),$(TOOL_REPO)/$(TOOL_SRC_$(1)))

# What a tool binary is built FROM, and how each input reaches make:
#   - every V file compiled in, vlib's included, and the C/headers beside them, plus every
#     #flag -I directory and C source the build hands the C compiler: bin/.tool-<name>.d,
#     written by scripts/build_tool.sh from V's -dump-files and -dump-c-flags;
#   - the compiler and how it is asked, and where: the signature below — the tool's own path (a
#     record from a moved checkout names the old one), the V command, the binary it resolves
#     to, `v version`, the tool's flags and $VFLAGS — recorded in bin/.tool-<name>.sig
#     by the build and compared here, at parse time; a different one rebuilds the tool;
#   - this file and the helper: prerequisites of the rule.
# A tool missing either record (a binary the old common.mk left, a build interrupted) is rebuilt.
# tools/loom2v/no_v_run_makefiles_test.v changes each kind of input and asks make.
TOOL_V_PATH    := $(shell command -v $(firstword $(V)) 2>/dev/null)
TOOL_V_VERSION := $(shell $(V) version 2>/dev/null)
tool_sig = $(strip $(TOOL_DIR)/.tool-$(1) | $(V) | $(TOOL_V_PATH) | $(TOOL_V_VERSION) | $(TOOL_FLAGS_$(1)) | $(VFLAGS))
# string equality: each a substring of the other (findstring is literal, filter is not)
tool_same = $(and $(findstring $(1),$(2)),$(findstring $(2),$(1)))
tool_recorded = $(and $(wildcard $(TOOL_DIR)/.tool-$(1).d),$(call tool_same,$(call tool_sig,$(1)),$(strip $(if $(wildcard $(TOOL_DIR)/.tool-$(1).sig),$(file <$(TOOL_DIR)/.tool-$(1).sig)))))

$(TOOL_DIR)/.tool-%: $(TOOL_REPO)/tools/tools.mk $(TOOL_REPO)/scripts/build_tool.sh
	@test -n "$(TOOL_SRC_$*)" || { echo "tools.mk: no tool named '$*'"; exit 1; }
	V="$(V)" TOOL_SIG='$(call tool_sig,$*)' $(TOOL_REPO)/scripts/build_tool.sh $@ "$(TOOL_FLAGS_$*)" $(call tool_src,$*)
# the records are written by the build above, never made on their own
$(TOOL_DIR)/.tool-%.d: ;
$(TOOL_DIR)/.tool-%.sig: ;

.PHONY: tool-unrecorded
$(foreach t,$(TOOLS),$(if $(call tool_recorded,$(t)),,$(eval $(TOOL_DIR)/.tool-$(t): tool-unrecorded)))

-include $(wildcard $(TOOL_DIR)/.tool-*.d)
.DEFAULT_GOAL := $(TOOL_GOAL)
