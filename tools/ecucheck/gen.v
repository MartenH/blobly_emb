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
import tools.ecumodel

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
			'enabled':        k(.boolean)
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
		// partition/thread/fb/handler required-ness + names + one-trigger live in ecumodel.validate
		// (shared with loom2v); here the schema only checks unknown keys + types for them.
		'partition':  {
			'name':    k(.str)
			'core':    k(.int)
			'trusted': k(.boolean)
			'thread':  sub(.arr, false, 'thread')
		}
		'thread':     {
			'name':     k(.str)
			'priority': k(.int)
		}
		'fb':         {
			'name':    k(.str)
			'thread':  k(.str)
			'handler': sub(.arr, false, 'handler')
		}
		'handler':    {
			'name':      k(.str)
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
	// the partition/thread/fb structural rules live in ecumodel, shared with loom2v so the
	// gate and the generator can't drift.
	errs << ecumodel.validate(doc)
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
			mut depth := 0 // open '[' of a multi-line array value; its continuation lines aren't keys
			for j < lines.len {
				l := lines[j].trim_space()
				if depth == 0 && l.starts_with('[') {
					break // the next table header
				}
				if l != '' && depth == 0 {
					if has_comment(l) && comment_at < 0 {
						comment_at = j
					}
					if !l.starts_with('#') {
						last_key = j
					}
				}
				depth += bracket_delta(l) // enter/leave a multi-line reads/writes array
				if depth < 0 {
					depth = 0
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

// bracket_delta counts '[' minus ']' outside strings and comments — to track multi-line arrays
// (a `reads = [` that closes on a later line) so their element lines aren't mistaken for keys.
fn bracket_delta(line string) int {
	mut d := 0
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `"` {
			i++
			for i < line.len && line[i] != `"` {
				if line[i] == `\\` {
					i++
				}
				i++
			}
		} else if c == `'` {
			i++
			for i < line.len && line[i] != `'` {
				i++
			}
		} else if c == `#` {
			break // comment: ignore the rest of the line
		} else if c == `[` {
			d++
		} else if c == `]` {
			d--
		}
		i++
	}
	return d
}

// has_comment reports whether the line has a `#` comment outside a quoted string. Honors both
// basic (`"`, with `\"` escapes) and literal (`'`) TOML strings so a `#` inside a value isn't
// mistaken for a comment (and an escaped quote doesn't leak the "in string" state).
fn has_comment(line string) bool {
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `"` {
			i++
			for i < line.len && line[i] != `"` {
				if line[i] == `\\` {
					i++
				}
				i++
			}
		} else if c == `'` {
			i++
			for i < line.len && line[i] != `'` {
				i++
			}
		} else if c == `#` {
			return true
		}
		i++
	}
	return false
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
