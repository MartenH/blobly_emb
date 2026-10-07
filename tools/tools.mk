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
v_sigtext = $(V) | $(TOOL_V_PATH) | $(TOOL_V_VERSION) | $(1) | $(VFLAGS)
v_sign = $(call tool_signed,$(1),$(call v_sigtext,$(2)))
# <stem>.sig holding <text>: rewritten only when it differs, so an unchanged signature keeps its age.
# Compared as written, never stripped: strip collapses the whitespace inside a quoted argument
# (-DMSG='"a b"' and '"a  b"' are two programs), so neither a signature's text nor its reading is.
tool_signed = $(if $(call tool_holds,$(2),$(if $(wildcard $(1).sig),$(file <$(1).sig))),,$(shell mkdir -p $(dir $(1)))$(file >$(1).sig,$(2)))$(1).sig
.PHONY: v-unrecorded
v-unrecorded: ;
# a signature is written while make reads the Makefile; never made on its own, and never deleted
# as an intermediate (an archive's is named by its objects' pattern rule alone)
%.sig: ;
.PRECIOUS: %.sig

# The same for what the C COMPILER reads: every target an image compiles C into — its ELF, an
# app.o, a bootloader's boot.elf — depends on every header its sources include (bootmap.h's flash
# addresses, a board header, the forced board.h, the generated boot_gen.h, xcore.h) and every file
# one includes textually (can_backend.c -> can_fdcan.c), from the compiler's own -MM -MP output:
# never a hand list of headers, which missed bootmap.h (#375). The rule runs its compiler through
# $(call c_build,<command>): <command> -o $@, then the same command with -MM -MP -MT $@ (archives and
# objects dropped — they are link inputs, and an object has its own record), so the record is taken
# with exactly the sources and flags that were compiled and no second list can drift from the
# first. A separate pass, because one gcc call that compiles several sources and links writes a
# -MMD record for the LAST source only.
#
# And HOW the compiler is run is an input, as it is for a transpile (v_sign) — a DEBUG=1 build, a
# board.mk edit to CAN_DEFS' bit timing or SYSTEM_CLOCK, a link address (#382):
# $$(call c_sign,<target>,$$(<command>)) keeps the command — every flag, define and source — and
# the compiler it names (its path and `--version`) in <target>.sig, rewritten only when it differs,
# and names it as a prerequisite. The command is a VARIABLE that the recipe passes to c_build too,
# and c_build refuses to run one its signature does not record, so the two cannot drift. Signed
# with $$: tools.mk turns on secondary expansion, so the signature is taken once the whole Makefile
# is read — a CFLAGS += after an include (sysnode's display and network defines) is in it. In the
# rule:
#
#     ELF_CMD = $(CC) $(CFLAGS) $(LDFLAGS) $(BUILD)/app.c $(BSP) $(TX_A)
#     $(BUILD)/$(NAME).elf: $(BUILD)/app.c $(BSP) $(TX_A) $(LD) $(call c_unrecorded,$(BUILD)/$(NAME).elf) \
#                           $$(call c_sign,$$@,$$(ELF_CMD))
#     	$(call c_build,$(ELF_CMD))
#     -include $(BUILD)/$(NAME).elf.d
#
# The record is the pass's stdout: -MF names ONE file, which each source's rule overwrites in
# turn (measured — it kept the last source's alone). Each source compiled gets
# an empty rule, as -MP gives each header one, so a source dropped from the list (a renamed board
# file, a network a config no longer asks for) remakes the target instead of stopping make with
# "No rule to make target". The record names this file too, as a V record names the rule that
# wrote it: a changed rule re-records. A literal comma in <command> splits the call's argument: name -Wl,... groups by a
# variable. As with v_deps, a failed compile or record removes the target, and a target with no
# record is remade. scripts/app_deps_check.sh pins the shape and asks make that a header's edit,
# and another flag, remakes each image, the bootloaders included.
c_build = $(call c_signed,$(1))$(c_check_$@)$(1) -o $@ && $(filter-out %.o %.a,$(1)) -MM -MP -MT $@ >$@.d.tmp && printf '%s\n' $(foreach s,$(filter %.c %.S,$(1)),'$(s):') '$@: $(TOOL_REPO)/tools/tools.mk' >>$@.d.tmp && mv -f $@.d.tmp $@.d || { rm -f $@ $@.d.tmp; exit 1; }
c_unrecorded = $(if $(wildcard $(1).d),,c-unrecorded)
.PHONY: c-unrecorded
c-unrecorded: ;
# the toolchain, as it describes itself — no command is parsed for it: what $(CC) -v reports
# (its version, target, configuration and driver), the cc1 it resolves to, and $(AR)'s version,
# each through the whole command as written, so a wrapper (ccache, env -i, VAR=val) is run as it
# would be and reports the compiler behind it. Asked once per make (once per value of CC and AR).
# A C rule's command runs $(CC) — or, for an archive, $(AR).
c_toolid = $(if $(call tool_same,x$(CC) | $(AR),$(C_TOOLID_FOR)),,$(eval C_TOOLID_FOR := x$$(CC) | $$(AR))$(eval C_TOOLID := $$(shell $$(CC) -v 2>&1; $$(CC) -print-prog-name=cc1 2>&1; $$(AR) --version 2>&1 | head -n 1)))$(C_TOOLID)
# <command> as <target> runs it: the command, the toolchain, how c_object compiles and records an
# archive object (its own text and the record filter's), and for an archive (a .a target) how
# c_archive makes it (its own text): the arguments they add and the record c_object writes are part
# of how an object or an archive is built, and neither has a record naming this file (below).
# c_archive only in an archive's: in the objects' it would recompile all of them for a rule that
# does not compile them. As written, whitespace and all (tool_signed).
c_sigtext = $(1) | $(c_toolid) | $(value c_object) | $(c_unpinned)$(if $(filter %.a,$(2)), | $(value c_archive))
# once per signature per make: an archive's objects (about 1,200 in sysnode) all name one
c_sign = $(if $(C_SIGNED_$(1)),$(1).sig,$(eval C_SIGNED_$(1) := 1)$(call tool_signed,$(1),$(call c_sigtext,$(2),$(1))))
# at recipe time: the rule names exactly one signature, and it records the command about to run
c_signed = $(if $(filter-out 1,$(words $(filter %.sig,$^))),$(error $@: a C rule names exactly one $$$$(call c_sign,...) among its prerequisites (tools/tools.mk)),$(if $(call tool_holds,$(call c_sigtext,$(1),$@),$(file <$(filter %.sig,$^))),,$(error $@: the command does not match its signature $(filter %.sig,$^) — the rule signs one variable and runs another (tools/tools.mk c_sign))))
#
# The pinned third-party archives (the ThreadX kernel, NetX Duo, LVGL) are compiled one object per
# source by a pattern rule, with the image's CFLAGS — the forced board.h among them — so they get
# the same two records, per object: $(call c_object,<command>) compiles $< with -MMD -MP (one
# source, so the compile writes its own record), and the archive's objects share ONE signature,
# keyed by their directory, since they are compiled the same way. A pattern target's record is asked
# for by name through secondary expansion, and the records are included by the object list:
#
#     TX_CMD = $(CC) $(CFLAGS)
#     $(BUILD)/tx/%.o: $(TX)/common/src/%.c $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/tx,$$(TX_CMD))
#     	@mkdir -p $(BUILD)/tx
#     	$(call c_object,$(TX_CMD))
#     -include $(call c_records,$(TX_OBJ))
#
# An object's record does not name this file: an edit here would recompile every kernel, network
# and graphics object (about 1,200 in sysnode) for a rule that does not change what they read.
# Nor the headers of the pinned trees themselves (third_party/): they move only when a pin does,
# with the sources beside them, and naming them made a no-op make in sysnode 2.5 s, where it is
# 0.5 s without them (1,200 objects; an LVGL one reads ~400 headers) — after moving a pin,
# `make clean`. What is recorded is what changes under a pinned tree: board.h forced into every
# object, the board's lv_conf.h and lv_attr.h, any repo header a pinned source reaches.
# What c_object itself adds to the command is in every signature instead (c_sigtext).
#
# A signature is taken whenever make reads the Makefile, whatever the goal, so a dry run or a
# what-if with OTHER flags (make -n DEBUG=1) rewrites it, and the next ordinary build remakes what
# it signs — as v_sign does for a transpile: a rebuild too many, never one too few.
c_object = $(call c_signed,$(1))$(1) -c $< -o $@ -MMD -MP -MT $@ -MF $@.d.tmp && $(c_unpinned) $@.d.tmp >$@.d.tmp2 && printf '%s\n' '$<:' >>$@.d.tmp2 && mv -f $@.d.tmp2 $@.d && rm -f $@.d.tmp || { rm -f $@ $@.d.tmp $@.d.tmp2; exit 1; }
# a record without the pinned trees' own headers (any third_party/ path): logical lines rejoined,
# those headers dropped from each, and a line left with nothing (their -MP rules) dropped
c_unpinned = awk '{ l = l $$0 } /\\$$/ { sub(/\\$$/, "", l); next } { n = split(l, w, " "); o = ""; for (i = 1; i <= n; i++) if (w[i] !~ /(^|\/)third_party\/.*\.h:?$$/) o = o " " w[i]; if (o != "") print substr(o, 2); l = "" }'
c_records = $(wildcard $(addsuffix .d,$(1)))
#
# An archive is made by ONE command, signed as a compile is — another ar, other flags, remake it:
#
#     $(TX_A): $(TX_OBJ) $$(call c_sign,$$@,$$(AR_CMD))
#     	$(call c_archive,$(AR_CMD))
#
# so the objects' own signature is keyed by their directory ($(BUILD)/tx), not by the archive.
AR_CMD = $(AR) -rc
c_archive = $(call c_signed,$(1))$(1) $@ $(filter-out %.sig,$^)
#
# A last check before a c_build target is linked, where its Makefile needs one: $(c_check_<target>),
# expanded in the recipe (boot/boot.mk refuses an application with no app-slot layout).
.SECONDEXPANSION:

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
tool_sig = $(TOOL_DIR)/.tool-$(1) | $(V) | $(TOOL_V_PATH) | $(TOOL_V_VERSION) | $(TOOL_FLAGS_$(1)) | $(VFLAGS)
# string equality: each a substring of the other (findstring is literal, filter is not)
tool_same = $(and $(findstring $(1),$(2)),$(findstring $(2),$(1)))
# <text> is what $(file <) read back of a file $(file >) wrote it to. The writer adds one newline
# and the reader should take it off, but GNU make 4.3's sometimes keeps it (it tests the end
# against a pointer into a buffer the read may have moved; measured on sysnode's ELF signature),
# so the text is compared with and without that newline — and nothing else is normalised
tool_holds = $(or $(call tool_same,$(1),$(2)),$(call tool_same,$(1)$(tool_nl),$(2)))
define tool_nl


endef
# compared as written, as an image's signature is (tool_signed)
tool_recorded = $(and $(wildcard $(TOOL_DIR)/.tool-$(1).d),$(call tool_holds,$(call tool_sig,$(1)),$(if $(wildcard $(TOOL_DIR)/.tool-$(1).sig),$(file <$(TOOL_DIR)/.tool-$(1).sig))))

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
