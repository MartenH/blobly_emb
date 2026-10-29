// cover — BUILD/CI tool (heap is fine here). Reads the counters a `v -coverage <dir> test ...`
// run left in <dir> and writes docs/coverage.md: statement coverage per file of the code that
// goes into an image, by the file's OWN tests and by any test.
//
//   make coverage         # run the unit tests instrumented, write docs/coverage.md
//   make coverage-check   # the same, and exit 1 when a file's own coverage dropped
//
//   bin/.tool-cover <coverage dir> <scope dir>... [--check]
//
// The scope is the directories the run tested (the Makefile's COVER_DIRS), so what is measured
// and what is reported are one list.
module main

import os

const out_file = 'docs/coverage.md'

fn in_scope(rel string, scope []string) bool {
	return rel.ends_with('.v') && !rel.ends_with('_test.v') && rel.all_before('/') in scope
		&& !rel.contains('/gen/')
}

// sources lists every in-scope V source file, so a file no host test compiles is listed too.
fn sources(scope []string) []string {
	mut out := []string{}
	for d in scope {
		for f in os.walk_ext(d, '.v') {
			if in_scope(f, scope) {
				out << f
			}
		}
	}
	out.sort()
	return out
}

fn main() {
	args := os.args[1..].filter(!it.starts_with('--'))
	if args.len < 2 {
		eprintln('usage: cover <coverage dir> <scope dir>... [--check]')
		exit(2)
	}
	scope := args[1..]
	check_mode := '--check' in os.args
	root := os.real_path(os.getwd()) + '/'
	rel := fn [root, scope] (abs string) string {
		p := os.real_path(abs)
		if !p.starts_with(root) {
			return ''
		}
		r := p[root.len..]
		return if in_scope(r, scope) { r } else { '' }
	}
	measured := attribute(metas(args[0]), hits(args[0]), rel)
	if measured.len == 0 {
		eprintln('cover: no coverage data in ${args[0]} — was the suite run with -coverage?')
		exit(1)
	}
	mut covs := []Cov{}
	for f in sources(scope) {
		covs << measured[f] or { Cov{
			file: f
		} }
	}
	if check_mode {
		// a drop leaves the recorded file as it is, so the next check still fails on it
		lost := drops(parse_recorded(os.read_file(out_file) or { '' }), covs)
		for l in lost {
			eprintln('coverage-check: ${l}')
		}
		if lost.len > 0 {
			eprintln('coverage-check: ${lost.len} file(s) lost own-test coverage. Add tests, or — if the drop is intended — run `make coverage` and commit ${out_file} so the review sees it.')
			exit(1)
		}
	}
	os.write_file(out_file, render(covs)) or { panic(err) }
	println('cover: ${covs.filter(it.built).len} of ${covs.len} files measured -> ${out_file}')
}
