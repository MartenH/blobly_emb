module main

import os

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

// runs_v_run: one of the line's shell commands invokes the V compiler (`$(V)`, `$(VEXE)`, a
// bare `v`, any of them behind make's `@`/`-`/`+` recipe prefixes) with `run`
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
		i := toks.index(toks.filter(it in ['$(V)', '\${V}', '$(VEXE)', 'v'])[0] or { continue })
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
