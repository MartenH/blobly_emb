module main

import os
import time

// No Makefile runs a repo tool through `v run`. `v run` derives its binary's path from the tool's
// SOURCE path and deletes it on exit, so two makes running one tool at once (`make -j` over a
// system's nodes, two examples generated side by side) write, exec and delete ONE file, and one
// of them dies with `No such file or directory` (#313, #333). tools/tools.mk is the one rule that
// replaces it: build the tool once into the including directory's bin/, then run that binary.

const skip_dirs = ['.git', '.claude', 'third_party', 'vlang', 'bin', 'build']

// makefiles: every Makefile and *.mk in the repo. os.ls, not os.glob: V's glob mangles a path
// with a repeated component, which CI's checkout (/home/runner/work/blobly_emb/blobly_emb) has.
fn makefiles(dir string) []string {
	mut out := []string{}
	mut names := os.ls(dir) or { panic(err) }
	names.sort()
	for n in names {
		p := os.join_path(dir, n)
		if os.is_dir(p) && !os.is_link(p) {
			if n !in skip_dirs {
				out << makefiles(p)
			}
		} else if n == 'Makefile' || n.ends_with('.mk') {
			out << p
		}
	}
	return out
}

// logical_lines: the file's lines with `\` continuations joined and comment lines dropped
fn logical_lines(src string) []string {
	mut out := []string{}
	mut cur := ''
	for l in src.split_into_lines() {
		if cur == '' && l.trim_space().starts_with('#') {
			continue
		}
		if l.trim_right(' ').ends_with('\\') {
			cur += l.trim_right(' ').trim_right('\\') + ' '
			continue
		}
		out << cur + l
		cur = ''
	}
	if cur != '' {
		out << cur
	}
	return out
}

// runs_v_run: one of the line's shell commands invokes the V compiler (`$(V)`, `$(VEXE)`, their
// `${...}` spellings, a bare `v`, any of them behind make's `@`/`-`/`+` prefixes) with `run`
fn runs_v_run(line string) bool {
	mut cmds := [line.trim_space()]
	for sep in ['&&', '||', ';', '|'] {
		mut next := []string{}
		for c in cmds {
			next << c.split(sep)
		}
		cmds = next.clone()
	}
	for c in cmds {
		toks := c.fields().map(it.trim_left('@-+'))
		i := toks.index(toks.filter(it in ['$(V)', '\${V}', '$(VEXE)', '\${VEXE}', 'v'])[0] or { continue })
		if 'run' in toks[i + 1..] {
			return true
		}
	}
	return false
}

// tool_refs: the $(TOOL_<name>) variables a line names
fn tool_refs(line string) []string {
	mut out := []string{}
	mut rest := line
	for {
		i := rest.index('$(TOOL_') or { break }
		j := rest[i..].index(')') or { break }
		name := rest[i + 7..i + j]
		if !name.starts_with('SRC_') && !name.starts_with('FLAGS_') && name !in ['REPO', 'DIR', 'GOAL'] {
			out << name
		}
		rest = rest[i + j..]
	}
	return out
}

// rule_header: the line opens a rule (`target: prereqs`), not an assignment (`X := y`)
fn rule_header(line string) bool {
	if line.starts_with('\t') || line.trim_space() == '' {
		return false
	}
	c := line.index(':') or { return false }
	if c + 1 < line.len && line[c + 1] == `=` {
		return false
	}
	e := line.index('=') or { return true }
	return c < e
}

fn repo_tools() []string {
	src := os.read_file(os.join_path(@VMODROOT, 'tools', 'tools.mk')) or { panic(err) }
	mut out := []string{}
	for l in src.split_into_lines() {
		if l.starts_with('TOOL_SRC_') {
			out << l.all_after('TOOL_SRC_').all_before(' ').all_before(':')
		}
	}
	return out
}

fn test_no_makefile_runs_a_repo_tool_through_v_run() {
	mks := makefiles(@VMODROOT)
	assert mks.len >= 40, 'found only ${mks.len} Makefiles: ${mks}'
	assert os.join_path(@VMODROOT, 'Makefile') in mks
	assert os.join_path(@VMODROOT, 'examples', 'common.mk') in mks
	for mk in mks {
		for l in logical_lines(os.read_file(mk) or { panic(err) }) {
			assert !runs_v_run(l), '${mk}: runs a tool through `v run` — build it with tools/tools.mk instead: ${l.trim_space()}'
		}
	}
}

// a $(TOOL_x) that is not defined expands to nothing, and the recipe then runs the tool's first
// ARGUMENT as a command; a tool that is not a prerequisite of its rule is never built, or is
// stale. So: tools.mk defines it, the Makefile includes tools.mk, and the rule depends on it.
fn test_every_tool_a_makefile_runs_is_defined_included_and_a_prerequisite() {
	known := repo_tools()
	assert 'loom2v' in known && 'sysgen' in known, 'tools.mk lists ${known}'
	mut used := 0
	for mk in makefiles(@VMODROOT) {
		if mk.ends_with('tools.mk') {
			continue
		}
		src := os.read_file(mk) or { panic(err) }
		includes := src.contains('include \$(REPO)/tools/tools.mk')
			|| src.contains('include tools/tools.mk')
			|| src.contains('include \$(REPO)/examples/common.mk')
		mut header := ''
		for l in logical_lines(src) {
			if rule_header(l) {
				header = l
			}
			for t in tool_refs(l) {
				used++
				assert t in known, '${mk}: \$(TOOL_${t}) is not a tool tools/tools.mk defines (${known})'
				assert includes, '${mk}: uses \$(TOOL_${t}) without including tools/tools.mk'
				if l.starts_with('\t') {
					assert header.contains('\$(TOOL_${t})'), '${mk}: runs \$(TOOL_${t}) in a rule that does not depend on it: ${header}'
				}
			}
		}
	}
	assert used >= 30, 'only ${used} tool uses found — is the scan reading the Makefiles?'
}

fn test_the_scan_recognises_v_run() {
	assert runs_v_run('\tcd $(REPO) && $(V) run tools/loom2v a b')
	assert runs_v_run('\t$(V) -enable-globals run tools/sysgen $(SYSTEM)')
	assert runs_v_run('\tv run tools/trace/gen.v')
	assert !runs_v_run('\t$(V) -o bin/app examples/x')
	assert !runs_v_run('run: all')
	assert !runs_v_run('\t$(MAKE) -C examples/$(NAME) run')
	assert runs_v_run('\t@$(V) run tools/x')
	assert runs_v_run('\t-v run tools/x')
	assert runs_v_run('\t\${V} run tools/x')
	assert runs_v_run('\tcd .. && \${VEXE} -prod run tools/x')
	assert runs_v_run('\tif [ -f a ]; then $(V) run tools/x a; fi')
	assert !runs_v_run('\tcd $(REPO) && $(V) -o bin/app x && ./bin/app run')
	assert tool_refs('\tcd $(REPO) && $(TOOL_loom2v) x $(TOOL_DIR)') == ['loom2v']
	assert rule_header('gen/.stamp: ecu.toml $(TOOL_loom2v)')
	assert !rule_header('NAME := x')
	assert !rule_header('X = a:b')
}

// default_goal asks make which target a plain `make` in `dir` builds. The goal named is one no
// Makefile has, so make reads everything, prints its database and stops without running a
// recipe; `-o gen/loom_build.mk` keeps it from remaking the one include that has a remake rule
// (which would run generation). Nothing is built and nothing is written.
fn default_goal(dir string, extra string) string {
	r := os.execute('make -C ${os.quoted_path(dir)} -pq -o gen/loom_build.mk ${extra} no-such-goal-probe 2>/dev/null')
	mut goal := ''
	for l in r.output.split_into_lines() {
		if l.starts_with('.DEFAULT_GOAL :=') {
			goal = l.all_after(':=').trim_space()
		}
	}
	return goal
}

// tools.mk declares explicit targets (a tool with no dependency list, the lists themselves); the
// first explicit target make reads is the default goal, so a plain `make` once built a tool and
// stopped (codex on #356). Every Makefile keeps its own goal, with the tools' lists present and
// with none at all (an empty TOOL_DIR: every tool unrecorded, the case that broke it).
fn test_including_tools_mk_keeps_every_default_goal() {
	empty := os.join_path(os.vtmp_dir(), 'tools_mk_goal_${os.getpid()}')
	os.mkdir_all(empty) or { panic(err) }
	defer {
		os.rmdir_all(empty) or {}
	}
	mut n := 0
	for mk in makefiles(@VMODROOT) {
		if os.file_name(mk) != 'Makefile' {
			continue
		}
		dir := os.dir(mk)
		want := if dir == @VMODROOT { 'example' } else { 'all' }
		for extra in ['', 'TOOL_DIR=${os.quoted_path(empty)}'] {
			got := default_goal(dir, extra)
			assert got == want, '${mk} ${extra}: a plain `make` builds `${got}`, not `${want}`'
			n++
		}
	}
	assert n >= 80, 'asked make about only ${n / 2} Makefiles'
}

// make_q: does make consider `target` up to date? (`-q` runs no recipe and builds nothing)
fn make_q(dir string, target string, extra string) bool {
	return os.execute('${extra} make -q -C ${os.quoted_path(dir)} ${os.quoted_path(target)} 2>/dev/null').exit_code == 0
}

fn set_mtime(path string, t i64) {
	os.utime(path, int(t), int(t)) or { panic(err) }
}

// A cached tool binary is only as good as the record of what it was built from. One probe tool,
// built through tools.mk, and every kind of input tools.mk lists changed in turn: each must
// make make call the binary out of date, and nothing else may (the baseline is up to date).
fn test_a_tool_is_rebuilt_when_any_input_changes() {
	d := os.join_path(os.vtmp_dir(), 'tools_mk_inputs_${os.getpid()}')
	os.mkdir_all(os.join_path(d, 'src')) or { panic(err) }
	os.mkdir_all(os.join_path(d, 'inc')) or { panic(err) }
	defer {
		os.rmdir_all(d) or {}
	}
	src := os.join_path(d, 'src', 'probe.v')
	hdr := os.join_path(d, 'inc', 'probe.h')
	os.write_file(src, 'module main\n\n#flag -I ${d}/inc\n#include "probe.h"\n\nfn main() {\n\tprintln(\'probe\')\n}\n') or {
		panic(err)
	}
	os.write_file(hdr, '#define PROBE 1\n') or { panic(err) }
	os.write_file(os.join_path(d, 'Makefile'), 'REPO := ${@VMODROOT}\nTOOL_SRC_probe := ${src}\ninclude \$(REPO)/tools/tools.mk\nall: \$(TOOL_probe)\n') or {
		panic(err)
	}
	fake := os.join_path(d, 'fakev.sh')
	os.write_file(fake, '#!/bin/sh\nexec ${os.quoted_path(@VEXE)} "\$@"\n') or { panic(err) }
	os.chmod(fake, 0o755) or { panic(err) }
	v := 'V=${os.quoted_path(@VEXE)}'
	build := os.execute('make -C ${os.quoted_path(d)} all ${v} 2>&1')
	assert build.exit_code == 0, build.output
	tool := os.join_path(d, 'bin', '.tool-probe')
	deps := os.read_file(tool + '.d') or { panic(err) }
	assert deps.contains('/vlib/builtin/'), 'vlib is not in the dependency list'

	// every input in the past, the binary now: up to date
	old := i64(1_000_000_000)
	now := time.now().unix()
	for f in [src, hdr] {
		set_mtime(f, old)
	}
	set_mtime(tool, now)
	assert make_q(d, tool, v), 'a freshly built tool is out of date: the test proves nothing'

	// a V source, a header reached only through `#flag -I`, a new file beside either
	for f in [src, hdr] {
		set_mtime(f, now + 1000)
		assert !make_q(d, tool, v), '${f} changed and the tool is still up to date'
		set_mtime(f, old)
	}
	for f in [os.join_path(d, 'src', 'extra.v'), os.join_path(d, 'inc', 'extra.h')] {
		os.write_file(f, '') or { panic(err) }
		set_mtime(f, now + 1000)
		assert !make_q(d, tool, v), '${f} appeared and the tool is still up to date'
		os.rm(f) or { panic(err) }
	}
	assert make_q(d, tool, v)

	// the compiler and how it is asked: another V, $VFLAGS, the tool's flags
	assert !make_q(d, tool, 'V=${os.quoted_path(fake)}'), 'another compiler and the tool is still up to date'
	assert !make_q(d, tool, '${v} VFLAGS=-g'), 'VFLAGS changed and the tool is still up to date'
	assert !make_q(d, tool, '${v} TOOL_FLAGS_probe=-g'), 'the tool flags changed and it is still up to date'

	// no record of what it was built from
	for rec in ['.d', '.sig'] {
		os.mv(tool + rec, tool + rec + '.away') or { panic(err) }
		assert !make_q(d, tool, v), 'no ${rec} and the tool is still up to date'
		os.mv(tool + rec + '.away', tool + rec) or { panic(err) }
	}
	assert make_q(d, tool, v)

	// a header behind `#flag -I` deleted (the wildcard alone would just stop naming it)
	os.mv(hdr, hdr + '.away') or { panic(err) }
	assert !make_q(d, tool, v), 'a header was deleted and the tool is still up to date'
	os.mv(hdr + '.away', hdr) or { panic(err) }
	set_mtime(hdr, old)
	assert make_q(d, tool, v)

	// the same records under another path (a moved checkout): they name the old output
	moved := d + '_moved'
	os.cp_all(d, moved, true) or { panic(err) }
	defer {
		os.rmdir_all(moved) or {}
	}
	mtool := os.join_path(moved, 'bin', '.tool-probe')
	set_mtime(mtool, now)
	assert !make_q(moved, mtool, v), 'a record from another path vouches for the tool'

	// tools.mk and the helper are prerequisites of every tool (asked of make, not of the text)
	db := os.execute('make -pq -C ${os.quoted_path(d)} ${v} no-such-goal-probe 2>/dev/null').output
	rule := db.split_into_lines().filter(it.starts_with(os.join_path(d, 'bin', '.tool-%:')))
	assert rule.len == 1, 'no tool rule in the database'
	assert rule[0].contains('/tools/tools.mk') && rule[0].contains('/scripts/build_tool.sh'), rule[0]
}
