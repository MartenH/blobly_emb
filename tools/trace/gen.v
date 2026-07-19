// trace — BUILD/CI tool (heap is fine here). Reads requirements/*.toml plus the
// verification links — inline `@verifies REQ-...` tags in tests, and
// requirements/verifications.toml for analysis (a command to run) and review
// (a sign-off) — and writes docs/traceability.md: per-requirement coverage and a
// per-context matrix. Requirements carry NO pointer to code or tests; the
// verification declares what it covers.
//
//   v run tools/trace/gen.v           # write docs/traceability.md
//   v run tools/trace/gen.v --check   # also exit nonzero on a FAILED requirement
module main

import os
import toml

struct Req {
	id      string
	title   string
	status  string // authoring lifecycle: draft | agreed
	method  string
	asil    string
	derives string
}

struct Verif {
	method  string
	source  string
	context string
	result  string // pass | fail | pending | approved
}

fn s(m map[string]toml.Any, k string) string {
	return (m[k] or { toml.Any('') }).string()
}

fn arr(a toml.Any) []toml.Any {
	return a.array()
}

fn main() {
	check_mode := '--check' in os.args

	// 1) requirements
	mut reqs := []Req{}
	mut rfiles := os.walk_ext('requirements', '.toml')
	rfiles.sort()
	for f in rfiles {
		if os.file_name(f) == 'verifications.toml' {
			continue
		}
		doc := toml.parse_file(f) or { panic('parse ${f}: ${err}') }
		for e in arr(doc.value('req')) {
			m := e.as_map()
			if s(m, 'id') == '' {
				continue
			}
			reqs << Req{
				id:      s(m, 'id')
				title:   s(m, 'title')
				status:  s(m, 'status')
				method:  s(m, 'method')
				asil:    s(m, 'asil')
				derives: s(m, 'derives')
			}
		}
	}

	mut vmap := map[string][]Verif{}
	mut ctxset := map[string]bool{}

	// 2a) inline @verifies tags in tests
	mut tfiles := os.walk_ext('examples', '.lua')
	// examples too: they carry V e2e tests (e.g. io_gpio) beside their lua ones
	for dir in ['comm', 'loom', 'osal', 'driver', 'ecu', 'wdg', 'boot', 'nvm', 'bcrypto', 'tools',
		'examples'] {
		for f in os.walk_ext(dir, '.v') {
			if f.ends_with('_test.v') {
				tfiles << f
			}
		}
	}
	for f in tfiles {
		lines := os.read_lines(f) or { continue }
		mut ids := []string{}
		for ln in lines {
			if !ln.contains('@verifies') {
				continue
			}
			for raw in ln.replace(',', ' ').replace('\t', ' ').split(' ') {
				id := raw.trim('.;)(*/ \t')
				if id.starts_with('REQ-') || id.starts_with('SYS-REQ-') {
					ids << id
				}
			}
		}
		if ids.len == 0 {
			continue
		}
		is_lua := f.ends_with('.lua')
		// V unit tests run here for a live result; lua integration tests need the
		// vcan + blobly_net harness, so they stay linked (pending) until run.
		ctx := if is_lua { 'host/SocketCAN' } else { 'host/unit' }
		result := if is_lua {
			'pending'
		} else {
			// Reuse the SAME V binary that is running this generator (@VEXE), not a
			// plain `v` on PATH, so `make V=/path/to/v trace` stays consistent.
			// -enable-globals: some deterministic unit tests record call order in a
			// test-only global (fn-pointer tables can't capture state).
			if os.execute('${@VEXE} -enable-globals test ${f}').exit_code == 0 {
				'pass'
			} else {
				'fail'
			}
		}
		ctxset[ctx] = true
		for id in ids {
			vmap[id] << Verif{
				method:  'test'
				source:  os.file_name(f)
				context: ctx
				result:  result
			}
		}
	}

	// 2b) analysis (run a command) + review (sign-off)
	if os.exists('requirements/verifications.toml') {
		doc := toml.parse_file('requirements/verifications.toml') or { panic(err) }
		for c in arr(doc.value('check')) {
			m := c.as_map()
			ctx := s(m, 'context')
			cmd := s(m, 'command')
			// method defaults to 'analysis'; an on-target check declares method='test'.
			mut meth := s(m, 'method')
			if meth == '' {
				meth = 'analysis'
			}
			// skip_exit (opt-in, per check): the exit code that means "not run" -> pending,
			// e.g. an on-target test with no board attached. NOT global: `make lint` exits 2
			// on a real invariant violation, which must stay 'fail' (GNU make: 2 = errors).
			skip_code := int((m['skip_exit'] or { toml.Any(-1) }).int())
			mut result := 'pending'
			if cmd != '' {
				ec := os.execute(cmd).exit_code
				result = if ec == 0 { 'pass' } else if ec == skip_code { 'pending' } else { 'fail' }
			}
			ctxset[ctx] = true
			for v in arr(m['verifies'] or { toml.Any([]toml.Any{}) }) {
				vmap[v.string()] << Verif{
					method:  meth
					source:  s(m, 'id')
					context: ctx
					result:  result
				}
			}
		}
		for r in arr(doc.value('review')) {
			m := r.as_map()
			ctx := s(m, 'context')
			result := if s(m, 'approved_by') != '' { 'approved' } else { 'pending' }
			ctxset[ctx] = true
			for v in arr(m['verifies'] or { toml.Any([]toml.Any{}) }) {
				vmap[v.string()] << Verif{
					method:  'review'
					source:  s(m, 'id')
					context: ctx
					result:  result
				}
			}
		}
	}

	mut contexts := ctxset.keys()
	contexts.sort()

	// 3) direct coverage status per requirement
	// A requirement is verified only when EVERY linked verification has passed; a
	// single pending (unrun lua / unapproved review) one keeps it covered, and any
	// failure makes it failed. (Per-context coverage still shows in the matrix.)
	direct := fn (vs []Verif) string {
		if vs.len == 0 {
			return 'uncovered'
		}
		mut all_pass := true
		for v in vs {
			if v.result == 'fail' {
				return 'failed'
			}
			if v.result != 'pass' && v.result != 'approved' {
				all_pass = false
			}
		}
		return if all_pass { 'verified' } else { 'covered' }
	}
	mut st := map[string]string{}
	for r in reqs {
		st[r.id] = direct(vmap[r.id] or { []Verif{} })
	}

	// derivation rollup (the ISO 26262 chain): a requirement with no direct pass is
	// 'verified' once every requirement that derives from it is verified. Track those
	// as `derived` so the report shows how they were met.
	mut children := map[string][]string{}
	for r in reqs {
		if r.derives != '' {
			children[r.derives] << r.id
		}
	}
	mut derived := map[string]bool{}
	for {
		mut changed := false
		for r in reqs {
			if st[r.id] == 'verified' || st[r.id] == 'failed' {
				continue
			}
			ch := children[r.id] or { []string{} }
			if ch.len == 0 {
				continue
			}
			mut all := true
			for c in ch {
				if st[c] != 'verified' {
					all = false
					break
				}
			}
			if all {
				st[r.id] = 'verified'
				derived[r.id] = true
				changed = true
			}
		}
		if !changed {
			break
		}
	}

	mut n_verified := 0
	mut n_covered := 0
	mut n_uncovered := 0
	mut n_failed := 0
	for r in reqs {
		match st[r.id] {
			'verified' { n_verified++ }
			'covered' { n_covered++ }
			'failed' { n_failed++ }
			else { n_uncovered++ }
		}
	}

	// 4) emit docs/traceability.md
	mut b := []string{}
	b << '<!-- Generated by tools/trace from requirements/*.toml — DO NOT EDIT. -->'
	b << '# Requirement traceability'
	b << ''
	b << 'Generated from `requirements/*.toml` + verification links. See'
	b << '`requirements/README.md` for the method.'
	b << ''
	b << '| total | verified | covered (pending) | uncovered | failed |'
	b << '|---|---|---|---|---|'
	b << '| ${reqs.len} | ${n_verified} | ${n_covered} | ${n_uncovered} | ${n_failed} |'
	b << ''
	b << '- **verified** — a linked verification passed.  **covered** — linked but no pass recorded in this run.'
	b << '- **uncovered** — no verification linked (a gap).  **failed** — a linked verification ran and failed.'
	b << ''
	b << '## Requirements'
	b << ''
	b << '| req | asil | method | status | verifications |'
	b << '|---|---|---|---|---|'
	for r in reqs {
		vs := vmap[r.id] or { []Verif{} }
		mut srcs := []string{}
		for v in vs {
			srcs << '${v.source} (${v.result})'
		}
		mut joined := if srcs.len > 0 { srcs.join(', ') } else { '—' }
		if derived[r.id] {
			joined = '↳ derived (all children verified)'
		}
		b << '| ${r.id} | ${r.asil} | ${r.method} | ${st[r.id]} | ${joined} |'
	}
	b << ''
	b << '## Matrix — requirement × execution context'
	b << ''
	mut hdr := '| req |'
	mut sep := '|---|'
	for c in contexts {
		hdr += ' ${c} |'
		sep += '---|'
	}
	b << hdr
	b << sep
	for r in reqs {
		mut row := '| ${r.id} |'
		vs := vmap[r.id] or { []Verif{} }
		for c in contexts {
			mut cell := ' |'
			mut pass := false
			mut fail := false
			mut pend := false
			for v in vs {
				if v.context != c {
					continue
				}
				if v.result == 'fail' {
					fail = true
				} else if v.result == 'pass' || v.result == 'approved' {
					pass = true
				} else {
					pend = true
				}
			}
			if fail {
				cell = ' ✗ |'
			} else if pass {
				cell = ' ✓ |'
			} else if pend {
				cell = ' · |'
			}
			row += cell
		}
		b << row
	}
	b << ''

	os.write_file('docs/traceability.md', b.join('\n')) or { panic(err) }
	println('trace: ${reqs.len} reqs — ${n_verified} verified, ${n_covered} covered, ${n_uncovered} uncovered, ${n_failed} failed -> docs/traceability.md')

	if check_mode {
		mut n_gap := 0
		for r in reqs {
			// Only `agreed` requirements are gated (draft = work in progress, exempt).
			// An agreed requirement must be `verified`; failed / covered (pending) /
			// uncovered all count as an unmet gate.
			if r.status == 'agreed' && st[r.id] != 'verified' {
				eprintln('trace-check: agreed but ${st[r.id]} — ${r.id}')
				n_gap++
			}
		}
		if n_gap > 0 {
			eprintln('trace-check: ${n_gap} agreed requirement(s) not verified')
			exit(1)
		}
	}
}
