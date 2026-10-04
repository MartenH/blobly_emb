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
#     TRANSPILE_FLAGS = -freestanding ... -path "..."
#     $(BUILD)/app.c: main.v gen/.stamp $(call v_unrecorded,$(BUILD)/app.c) \
#                     $(call v_sign,$(BUILD)/app.c,$(TRANSPILE_FLAGS)) | $(BUILD)
#     	cd $(REPO) && $(V) $(TRANSPILE_FLAGS) $(call v_dump,$@) -o .../$(BUILD)/app.c .../main.v
#     	$(call v_deps,$@)
#     -include $(BUILD)/app.c.d
#
# scripts/app_deps_check.sh asks make that a module's edit remakes every image importing it.
#
# A target with no record is remade, whatever its age: the record is what makes it current (a
# build from before the record existed, or one whose recording failed). Name the target's
# $(call v_unrecorded,<target>) as a prerequisite; v_deps failing removes the C it was recording,
# so the C and its record exist together or not at all.
v_dump = -dump-files $(CURDIR)/$(1).files
v_deps = { VDEPS_BASE=$(TOOL_REPO) $(TOOL_REPO)/scripts/vdeps.sh $(1) $(1).files >$(1).d.tmp && mv -f $(1).d.tmp $(1).d; } || { rm -f $(1) $(1).d.tmp; exit 1; }
v_unrecorded = $(if $(wildcard $(1).d),,v-unrecorded)
#
# How a transpile is run is an input too, as a tool's compiler is (tool_sig above): the V command,
# its binary and version, the flags the rule passes — the image's defines among them
# (-d boot_doip, -d loom_max_tasks) — and $(VFLAGS). $(call v_sign,<target>,<flags>) keeps that in
# <target>.sig, rewritten while make reads the Makefile and only when it differs, and names it as
# a prerequisite: a changed define or compiler remakes the C. The rule's recipe runs V with the
# same <flags>, so the signature is what was actually run.
v_sigtext = $(strip $(V) | $(TOOL_V_PATH) | $(TOOL_V_VERSION) | $(1) | $(VFLAGS))
v_sign = $(if $(call tool_same,$(call v_sigtext,$(2)),$(strip $(if $(wildcard $(1).sig),$(file <$(1).sig)))),,$(shell mkdir -p $(dir $(1)))$(file >$(1).sig,$(call v_sigtext,$(2))))$(1).sig
.PHONY: v-unrecorded
v-unrecorded: ;
# the signature is written while make reads the Makefile; never made on its own
%.c.sig: ;

# The same for what the C COMPILER reads: every target an image compiles C into — its ELF, an
# app.o, a bootloader's boot.elf — depends on every header its sources include (bootmap.h's flash
# addresses, a board header, the forced board.h, the generated boot_gen.h, xcore.h) and every file
# one includes textually (can_backend.c -> can_fdcan.c), from the compiler's own -MM -MP output:
# never a hand list of headers, which missed bootmap.h (#375). The rule runs its compiler through
# $(call c_build,<command>): <command> -o $@, then the same command with -MM -MP -MT $@ (archives and
# objects dropped — they are link inputs, and an object has its own record), so the record is taken
# with exactly the sources and flags that were compiled and no second list can drift from the
# first. A separate pass, because one gcc call that compiles several sources and links writes a
# -MMD record for the LAST source only. In the rule:
#
#     $(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(TX_A) $(LD) $(call c_unrecorded,$(BUILD)/$(NAME).elf)
#     	$(call c_build,$(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) $(TX_A))
#     -include $(BUILD)/$(NAME).elf.d
#
# The record is the pass's stdout: -MF names ONE file, which each source's rule overwrites in
# turn (measured — it kept the last source's alone). Each source compiled gets
# an empty rule, as -MP gives each header one, so a source dropped from the list (a renamed board
# file, a network a config no longer asks for) remakes the target instead of stopping make with
# "No rule to make target". The record names this file too, as a V record names the rule that
# wrote it: a changed rule re-records. A literal comma in <command> splits the call's argument: name -Wl,... groups by a
# variable. As with v_deps, a failed compile or record removes the target, and a target with no
# record is remade. What it does NOT carry is the command's flags (no c_sign beside v_sign yet). scripts/app_deps_check.sh pins the shape and asks make that a header's edit remakes each
# image, the bootloaders included.
c_build = $(1) -o $@ && $(filter-out %.o %.a,$(1)) -MM -MP -MT $@ >$@.d.tmp && printf '%s\n' $(foreach s,$(filter %.c %.S,$(1)),'$(s):') '$@: $(TOOL_REPO)/tools/tools.mk' >>$@.d.tmp && mv -f $@.d.tmp $@.d || { rm -f $@ $@.d.tmp; exit 1; }
c_unrecorded = $(if $(wildcard $(1).d),,c-unrecorded)
.PHONY: c-unrecorded
c-unrecorded: ;

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

$(TOOL_DIR)/.tool-%: $(TOOL_REPO)/tools/tools.mk $(TOOL_REPO)/scripts/build_tool.sh $(TOOL_REPO)/scripts/vdeps.sh
	@test -n "$(TOOL_SRC_$*)" || { echo "tools.mk: no tool named '$*'"; exit 1; }
	V="$(V)" TOOL_SIG='$(call tool_sig,$*)' $(TOOL_REPO)/scripts/build_tool.sh $@ "$(TOOL_FLAGS_$*)" $(call tool_src,$*)
# the records are written by the build above, never made on their own
$(TOOL_DIR)/.tool-%.d: ;
$(TOOL_DIR)/.tool-%.sig: ;

.PHONY: tool-unrecorded
$(foreach t,$(TOOLS),$(if $(call tool_recorded,$(t)),,$(eval $(TOOL_DIR)/.tool-$(t): tool-unrecorded)))

-include $(wildcard $(TOOL_DIR)/.tool-*.d)
.DEFAULT_GOAL := $(TOOL_GOAL)
