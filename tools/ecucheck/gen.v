// ecucheck — BUILD-TIME schema validator for ecu.toml. V's `toml` lib validates syntax
// but knows nothing about OUR schema, so a misspelled or unknown key (`partiton`,
// `period_ns`) is silently ignored and surfaces later as a baffling codegen failure or
// wrong behaviour. ecucheck walks the parsed config against a declared schema — allowed
// keys (with "did you mean" for typos), required keys, and types — and enforces the
// cross-field rules (unique names, fb->thread resolves, one trigger per handler). It runs
// BEFORE the generators (cfg2v/loom2v/sigmap all parse the same file), reporting EVERY
// problem at once, so no generator ever sees an invalid config.
//
//   v run tools/ecucheck/gen.v <ecu.toml>
module main

import os
import toml

// Typ is the expected shape of a key's value.
enum Typ {
	str      // a string
	int      // an integer
	boolean  // a bool
	arr      // an array of tables (e.g. [[partition]])
	tbl      // a single sub-table (e.g. [trace.trigger] or inline tx = {...})
	str_arr  // an array of strings (reads/writes)
	namedmap // a table of arbitrary-named sub-tables (e.g. [bus.<name>])
	str_map  // a table of arbitrary string->string (e.g. signal fields)
}

// Key is one allowed key in a section: its type, whether it's required, and (for tbl/arr/
// namedmap) the context name of the sub-table's own schema.
struct Key {
	typ      Typ
	required bool
	sub      string
}

fn k(typ Typ) Key {
	return Key{
		typ: typ
	}
}

fn req(typ Typ) Key {
	return Key{
		typ:      typ
		required: true
	}
}

fn sub(typ Typ, required bool, ctx string) Key {
	return Key{
		typ:      typ
		required: required
		sub:      ctx
	}
}

// specs: context name -> its allowed keys. `top` is the document root.
fn specs() map[string]map[string]Key {
	return {
		'top':        {
			'import':    sub(.tbl, false, 'import')
			'telemetry': sub(.tbl, false, 'telemetry')
			'trace':     sub(.tbl, false, 'trace')
			'target':    sub(.tbl, false, 'target')
			'bus':       sub(.namedmap, false, 'bus')
			'nm':        sub(.namedmap, false, 'nm')
			'partition': sub(.arr, false, 'partition')
			'fb':        sub(.arr, false, 'fb')
			'signal':    sub(.arr, false, 'signal')
			'frame':     sub(.arr, false, 'frame')
			'isotp':     sub(.arr, false, 'isotp')
			'did':       sub(.arr, false, 'did')
			'route':     sub(.arr, false, 'route')
		}
		'import':     {
			'dbc': k(.str)
		}
		'telemetry':  {
			'enabled':   k(.boolean)
			'bus':       k(.str)
			'id':        k(.int)
			'detail_id': k(.int)
			'period_ms': k(.int)
		}
		'trace':      {
			'bus':            k(.str)
			'level':          k(.str)
			'buffer_records': k(.int)
			'mode':           k(.str)
			'pre_pct':        k(.int)
			'push_ms':        k(.int)
			'cmd_id':         k(.int)
			'rsp_id':         k(.int)
			'stat_id':        k(.int)
			'record_id':      k(.int)
			'dump_fc_id':     k(.int)
			'trigger':        sub(.tbl, false, 'trigger')
		}
		'trigger':    {
			'source':  k(.str)
			'signal':  k(.str)
			'address': k(.str)
			'when':    k(.str)
			'pre':     k(.int)
		}
		'target':     {
			'kind':    k(.str)
			'tick_ms': k(.int)
		}
		'bus':        {
			'interface': req(.str)
			'fd':        k(.boolean)
			'core':      k(.int)
		}
		'nm':         {
			'node_id':       k(.int)
			'tx_id':         k(.int)
			'rx_lo':         k(.int)
			'rx_hi':         k(.int)
			'pn_local':      k(.int)
			'msg_cycle_ms':  k(.int)
			'timeout_ms':    k(.int)
			'repeat_ms':     k(.int)
			'wait_sleep_ms': k(.int)
		}
		'partition':  {
			'name':    req(.str)
			'core':    req(.int)
			'trusted': k(.boolean)
			'thread':  sub(.arr, true, 'thread')
		}
		'thread':     {
			'name':     req(.str)
			'priority': k(.int)
		}
		'fb':         {
			'name':    req(.str)
			'thread':  req(.str)
			'handler': sub(.arr, true, 'handler')
		}
		'handler':    {
			'name':      req(.str)
			'period_ms': k(.int)
			'irq':       k(.str)
			'reads':     k(.str_arr)
			'writes':    k(.str_arr)
		}
		'signal':     {
			'name':      req(.str)
			'fields':    sub(.str_map, true, '')
			'from':      req(.str)
			'to':        req(.str)
			'transport': k(.str)
		}
		'frame':      {
			'name':  req(.str)
			'bus':   req(.str)
			'tx':    sub(.tbl, false, 'tx')
			'rx':    sub(.tbl, false, 'rx')
			'e2e':   sub(.tbl, false, 'e2e')
			'secoc': sub(.tbl, false, 'secoc')
		}
		'tx':         {
			'mode':         k(.str)
			'cycle_ms':     k(.int)
			'min_delay_ms': k(.int)
		}
		'rx':         {
			'timeout_ms': k(.int)
		}
		'e2e':        {
			'data_id':     k(.int)
			'crc_pos':     k(.int)
			'counter_pos': k(.int)
		}
		'secoc':      {
			'key':       k(.str)
			'data_id':   k(.int)
			'fresh_pos': k(.int)
			'mac_pos':   k(.int)
			'mac_len':   k(.int)
		}
		'isotp':      {
			'name':     req(.str)
			'bus':      req(.str)
			'rx_id':    req(.int)
			'tx_id':    req(.int)
			'bs':       k(.int)
			'stmin_ms': k(.int)
		}
		'did':        {
			'id':       req(.int)
			'ascii':    k(.str)
			'bytes':    k(.str)
			'writable': k(.boolean)
			'signal':   k(.str)
		}
		'route':      {
			'from': sub(.tbl, true, 'route_from')
			'to':   sub(.tbl, true, 'route_to')
		}
		'route_from': {
			'bus':   req(.str) // the source bus
			'frame': req(.str) // the DBC frame to forward (loom2v looks it up)
		}
		'route_to':   {
			'bus': req(.str) // the destination bus
			'id':  k(.int) // optional; 0/absent keeps the source id
		}
	}
}

// label maps a context to how its section reads in a message.
fn label(ctx string) string {
	return match ctx {
		'top' { '(top level)' }
		'thread' { '[[partition.thread]]' }
		'handler' { '[[fb.handler]]' }
		'trigger' { '[trace.trigger]' }
		'bus' { '[bus.*]' }
		'nm' { '[nm.*]' }
		'tx', 'rx', 'e2e', 'secoc' { 'inline ${ctx}' }
		'route_from' { '[[route]] from' }
		'route_to' { '[[route]] to' }
		'import', 'telemetry', 'trace', 'target' { '[${ctx}]' }
		else { '[[${ctx}]]' }
	}
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: ecucheck <ecu.toml>')
		exit(2)
	}
	path := os.args[1]
	doc := toml.parse_file(path) or {
		eprintln('ecucheck: parse ${path}: ${err}')
		exit(1)
	}
	sp := specs()
	mut errs := []string{}
	check_raw(os.read_file(path) or { '' }, mut errs)
	check_table(doc.to_any().as_map(), 'top', sp, mut errs)
	check_cross(doc, mut errs)
	fname := os.file_name(path)
	if errs.len > 0 {
		for e in errs {
			eprintln('${fname}: ${e}')
		}
		eprintln('ecucheck: ${errs.len} schema error(s) in ${fname}')
		exit(1)
	}
	eprintln('ecucheck: ${fname} ok')
}

// check_table validates one table against its context spec: unknown keys (with a suggestion),
// wrong types, then recurses into sub-tables; finally reports missing required keys.
fn check_table(m map[string]toml.Any, ctx string, sp map[string]map[string]Key, mut errs []string) {
	if ctx !in sp {
		return
	}
	keys := sp[ctx].clone()
	for name, v in m {
		key := keys[name] or {
			errs << '${label(ctx)}: unknown key "${name}"${suggest(name, keys.keys())} (allowed: ${keys.keys().join(', ')})'
			continue
		}
		if !type_ok(v, key.typ) {
			errs << '${label(ctx)} "${name}": expected ${type_name(key.typ)}, got ${actual(v)}'
			continue
		}
		match key.typ {
			.tbl {
				check_table(v.as_map(), key.sub, sp, mut errs)
			}
			.arr {
				for e in v.array() {
					check_table(e.as_map(), key.sub, sp, mut errs)
				}
			}
			.namedmap {
				for _, nv in v.as_map() {
					check_table(nv.as_map(), key.sub, sp, mut errs)
				}
			}
			.str_map {
				for fk, fv in v.as_map() {
					if fv !is string {
						errs << '${label(ctx)} "${name}": field "${fk}" must be a string type (e.g. "u16"), got ${actual(fv)}'
					}
				}
			}
			else {}
		}
	}
	for name, key in keys {
		if key.required && name !in m {
			errs << '${label(ctx)}: missing required key "${name}"'
		}
	}
}

// type_ok reports whether v matches the expected Typ.
fn type_ok(v toml.Any, typ Typ) bool {
	return match typ {
		.str {
			v is string
		}
		.int {
			v is i64
		}
		.boolean {
			v is bool
		}
		.arr {
			v is []toml.Any
		}
		.tbl, .namedmap, .str_map {
			v is map[string]toml.Any
		}
		.str_arr {
			if v is []toml.Any {
				mut ok := true
				for e in v {
					if e !is string {
						ok = false
					}
				}
				ok
			} else {
				false
			}
		}
	}
}

fn type_name(typ Typ) string {
	return match typ {
		.str { 'a string' }
		.int { 'an integer' }
		.boolean { 'a boolean' }
		.arr { 'an array of tables' }
		.tbl, .namedmap { 'a table' }
		.str_arr { 'an array of strings' }
		.str_map { 'a table of string values' }
	}
}

// actual names the concrete type of v, for a "got ..." message.
fn actual(v toml.Any) string {
	return match v {
		string { 'a string' }
		i64 { 'an integer' }
		bool { 'a boolean' }
		f64, f32 { 'a float' }
		[]toml.Any { 'an array' }
		map[string]toml.Any { 'a table' }
		else { 'another type' }
	}
}

// --- cross-field rules (the ones a per-key schema can't express) ---
fn check_cross(doc toml.Doc, mut errs []string) {
	mut part_names := map[string]bool{}
	mut thread_part := map[string]string{} // thread -> partition (globally unique)
	for p in arr(doc, 'partition') {
		m := p.as_map()
		pname := str_of(m, 'name')
		if pname != '' {
			if pname in part_names {
				errs << 'duplicate partition name "${pname}" — partition names must be unique'
			}
			part_names[pname] = true
			if !ident_ok(pname) {
				errs << 'partition name "${pname}" is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)'
			}
		}
		mut nthreads := 0
		for t in arr_of(m, 'thread') {
			nthreads++
			tname := str_of(t.as_map(), 'name')
			if tname == '' {
				continue
			}
			if !ident_ok(tname) {
				errs << 'thread name "${tname}" (partition "${pname}") is not a valid identifier'
			}
			if tname in thread_part {
				errs << 'duplicate thread name "${tname}" — thread names must be globally unique (already in partition "${thread_part[tname]}")'
			}
			thread_part[tname] = pname
		}
		if nthreads == 0 && pname != '' {
			errs << 'partition "${pname}" declares no [[partition.thread]] — every partition needs at least one thread'
		}
		// Mirror loom2v: multiple threads per partition need per-thread schedulers, not
		// generated yet. Reject here so `make check` doesn't pass a config `make gen` rejects.
		if nthreads > 1 {
			errs << 'partition "${pname}" declares ${nthreads} threads — multiple threads per partition is not generated yet (one scheduler per partition today); declare a single [[partition.thread]]'
		}
	}
	for c in arr(doc, 'fb') {
		cm := c.as_map()
		fbname := str_of(cm, 'name')
		if fbname != '' && !ident_ok(fbname) {
			errs << 'fb name "${fbname}" is not a valid identifier'
		}
		thr := str_of(cm, 'thread')
		if thr != '' && thr !in thread_part {
			errs << 'fb "${fbname}" names unknown thread "${thr}" (no [[partition.thread]] with that name)'
		}
		for h in arr_of(cm, 'handler') {
			hm := h.as_map()
			hname := str_of(hm, 'name')
			if hname != '' && !ident_ok(hname) {
				errs << 'fb "${fbname}" handler name "${hname}" is not a valid identifier'
			}
			// Mirror loom2v exactly: irq is a RESERVED trigger (ISR-context) not generated
			// yet, so reject it here rather than let `make check` pass then `make gen` fail.
			// The only supported trigger today is period_ms.
			has_period := 'period_ms' in hm
			has_irq := 'irq' in hm
			if has_irq {
				errs << 'fb "${fbname}" handler "${hname}": irq-triggered handlers are not generated yet (reserved trigger); use period_ms'
			} else if !has_period {
				errs << 'fb "${fbname}" handler "${hname}" needs a trigger — period_ms'
			}
		}
	}
}

// check_raw is a LEXICAL pass (independent of the buggy parser): V's TOML parser silently
// drops the key following a comment inside a nested `[[a.b]]` array-of-tables block
// (verified on `[[partition.thread]]` / `[[fb.handler]]`). The dropped key is invisible to
// the parse-based checks when it's optional, so scan the raw text and forbid comments inside
// such blocks outright.
fn check_raw(text string, mut errs []string) {
	lines := text.split_into_lines()
	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		// a nested [[a.b]] block: scan its body (until the next table header) and flag it if a
		// comment appears BEFORE a later key — that later key is what the parser drops. A
		// comment after the block's last key (before the next header) is harmless.
		if line.starts_with('[[') && line.contains('.') {
			mut j := i + 1
			mut comment_at := -1
			mut last_key := -1
			for j < lines.len {
				l := lines[j].trim_space()
				if l.starts_with('[') {
					break
				}
				if l != '' {
					if has_comment(l) && comment_at < 0 {
						comment_at = j
					}
					if !l.starts_with('#') {
						last_key = j
					}
				}
				j++
			}
			if comment_at >= 0 && last_key > comment_at {
				errs << 'line ${comment_at + 1}: comment inside ${line} drops the following key ' +
					'(a V TOML parser bug) — keep [[a.b]] blocks comment-free, move the note above the block'
			}
			i = j
			continue
		}
		i++
	}
}

// has_comment reports whether the line has a `#` comment outside of a quoted string.
fn has_comment(line string) bool {
	mut in_q := false
	for c in line {
		if c == `"` {
			in_q = !in_q
		} else if c == `#` && !in_q {
			return true
		}
	}
	return false
}

fn arr(doc toml.Doc, key string) []toml.Any {
	if v := doc.value_opt(key) {
		return v.array()
	}
	return []toml.Any{}
}

fn arr_of(m map[string]toml.Any, key string) []toml.Any {
	if v := m[key] {
		if v is []toml.Any {
			return v
		}
	}
	return []toml.Any{}
}

fn str_of(m map[string]toml.Any, key string) string {
	if v := m[key] {
		if v is string {
			return v
		}
	}
	return ''
}

fn ident_ok(s string) bool {
	if s == '' {
		return false
	}
	for i, c in s {
		alpha := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
		if i == 0 {
			if !alpha {
				return false
			}
		} else if !(alpha || (c >= `0` && c <= `9`)) {
			return false
		}
	}
	return true
}

// suggest finds the closest allowed key (edit distance <= 2) for an "did you mean" hint.
fn suggest(k string, allowed []string) string {
	mut best := ''
	mut bestd := 3
	for a in allowed {
		d := lev(k, a)
		if d < bestd {
			bestd = d
			best = a
		}
	}
	return if best != '' { ' — did you mean "${best}"?' } else { '' }
}

// lev is the Levenshtein edit distance between a and b.
fn lev(a string, b string) int {
	mut prev := []int{len: b.len + 1, init: index}
	mut cur := []int{len: b.len + 1}
	for i in 1 .. a.len + 1 {
		cur[0] = i
		for j in 1 .. b.len + 1 {
			cost := if a[i - 1] == b[j - 1] { 0 } else { 1 }
			mut mn := prev[j] + 1
			if cur[j - 1] + 1 < mn {
				mn = cur[j - 1] + 1
			}
			if prev[j - 1] + cost < mn {
				mn = prev[j - 1] + cost
			}
			cur[j] = mn
		}
		for j in 0 .. b.len + 1 {
			prev[j] = cur[j]
		}
	}
	return prev[b.len]
}
