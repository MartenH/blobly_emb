// cfgschema — THE schema of the two configuration files, ecu.toml and system.toml, as data.
//
// Every table and every key is one row: its type, whether it is required, its default, the values
// it may take (an enumeration or a min..max range) and one line saying what it means. Everything
// that needs to know a key reads it from here:
//   - ecucheck walks an ecu.toml against `ecu` (unknown keys, types, required keys — `check`);
//   - the scattered leaf checks (an enumeration, a range) take their bounds from `key()`, so a
//     limit is stated once — the relation checks (cross-key, cross-node) stay where they are;
//   - sysmodel takes each system.toml table's key set from `system`;
//   - tools/cfgdoc renders docs/config-reference.md and the JSON Schemas under schema/ from it.
//
// A bound that the RUNTIME owns (a DoIP timer's limits, a UDS table size) is read from the runtime
// module here, never copied: the schema states where the number lives, not a second copy of it.
module cfgschema

import toml

// Typ is the shape of a key's value.
pub enum Typ {
	str // a string
	int // an integer
	boolean // a bool
	arr // an array of tables (e.g. [[partition]])
	tbl // a single sub-table (e.g. [trace.trigger] or inline tx = {...})
	str_arr // an array of strings (reads/writes)
	int_arr // an array of integers (a [doip] tester list)
	id_range // an inclusive [lo, hi] pair of CAN ids (an NM peers range)
	namedmap // a table of arbitrary-named sub-tables (e.g. [bus.<name>])
	str_map // a table of arbitrary string->string (e.g. signal fields)
	val_map // a table of arbitrary name -> integer or bool (e.g. a [[param]]'s defaults)
	id // a CAN id: an integer literal OR a bus.dbc message name (string)
}

// Key is one allowed key of a table.
pub struct Key {
pub:
	name     string
	typ      Typ
	required bool
	sub      string // tbl / arr / namedmap: the context of the sub-table(s)
	def      string // the default as TOML spells it; '' = none (required, or absence is stated in desc)
	choices  []string // the values a string (or a string array's elements) may take; empty = any
	min      i64
	max      i64
	ranged   bool // min..max applies (an integer, or an integer array's elements)
	open_max bool // only the minimum bounds it (max is meaningless)
	desc     string
}

// Table is one context: a section of the file, or a sub-table inside one.
pub struct Table {
pub:
	ctx   string // the name the schema refers to it by
	label string // how it reads in a message and as a heading ("[trace]", "[[fb.handler]]")
	desc  string
	keys  []Key
	// a key this table does not name, whose value is a table, is checked against this context
	// instead of being refused ([nm] carries the legacy [nm.<bus>] blocks this way)
	table_keys string
}

// Schema is one file's tables; `root` is the document's own context.
pub struct Schema {
pub:
	file   string // 'ecu.toml'
	root   string
	title  string
	desc   string
	tables []Table
}

// ---- building rows (the data files read as one row per key) ----
fn k(name string, typ Typ) Key {
	return Key{
		name: name
		typ: typ
	}
}

fn req(name string, typ Typ) Key {
	return Key{
		name: name
		typ: typ
		required: true
	}
}

// sub: a table-shaped key whose content is checked against `ctx`
fn sub(name string, typ Typ, ctx string) Key {
	return Key{
		name: name
		typ: typ
		sub: ctx
	}
}

fn (k Key) required() Key {
	return Key{
		...k
		required: true
	}
}

fn (k Key) d(def string) Key {
	return Key{
		...k
		def: def
	}
}

fn (k Key) one_of(choices []string) Key {
	return Key{
		...k
		choices: choices
	}
}

fn (k Key) range(lo i64, hi i64) Key {
	return Key{
		...k
		min: lo
		max: hi
		ranged: true
	}
}

// at_least: a lower bound and no upper one
fn (k Key) at_least(lo i64) Key {
	return Key{
		...k
		min: lo
		max: max_i64
		ranged: true
		open_max: true
	}
}

fn (k Key) doc(s string) Key {
	return Key{
		...k
		desc: s
	}
}

fn tbl(ctx string, label string, desc string, keys []Key) Table {
	return Table{
		ctx: ctx
		label: label
		desc: desc
		keys: keys
	}
}

// ---- reading it ----

// table: the context `ctx`; a name the schema does not have is a defect of the CALLER
pub fn (s Schema) table(ctx string) Table {
	for t in s.tables {
		if t.ctx == ctx {
			return t
		}
	}
	panic('cfgschema: ${s.file} has no table "${ctx}"')
}

// has_table: whether `ctx` is one of this schema's tables
pub fn (s Schema) has_table(ctx string) bool {
	return s.tables.any(it.ctx == ctx)
}

// key: one key's row; asking for a key the schema does not have is a defect of the caller, so it
// panics — a check reading a bound the schema does not state would otherwise enforce nothing
pub fn (s Schema) key(ctx string, name string) Key {
	for key in s.table(ctx).keys {
		if key.name == name {
			return key
		}
	}
	panic('cfgschema: ${s.file} table "${ctx}" has no key "${name}"')
}

// names: the keys of a table, in schema order
pub fn (t Table) names() []string {
	return t.keys.map(it.name)
}

// in_range: v lies within the key's range (a key with no range takes everything)
pub fn (k Key) in_range(v i64) bool {
	return !k.ranged || (v >= k.min && v <= k.max)
}

// ---- the structural walk: unknown keys, types, required keys ----

// check validates a parsed document against the schema from its root — unknown keys (with a "did
// you mean"), wrong types, missing required keys — and returns every problem, in document order.
// Leaf VALUES (ranges, enumerations) are not judged here: they are the checks that read their
// bounds with key(), each with the context its message needs.
pub fn (s Schema) check(m map[string]toml.Any) []string {
	mut errs := []string{}
	s.check_table(m, s.root, mut errs)
	return errs
}

fn (s Schema) check_table(m map[string]toml.Any, ctx string, mut errs []string) {
	if !s.has_table(ctx) {
		return
	}
	t := s.table(ctx)
	names := t.names()
	for name, v in m {
		key := t.keys.filter(it.name == name)[0] or {
			if t.table_keys != '' && v is map[string]toml.Any {
				s.check_table(v, t.table_keys, mut errs)
				continue
			}
			errs << '${t.label}: unknown key "${name}"${suggest(name, names)} (allowed: ${names.join(', ')})'
			continue
		}
		if !type_ok(v, key.typ) {
			errs << '${t.label} "${name}": expected ${type_name(key.typ)}, got ${actual(v)}'
			continue
		}
		match key.typ {
			.tbl {
				s.check_table(v.as_map(), key.sub, mut errs)
			}
			.arr {
				for e in v.array() {
					s.check_table(e.as_map(), key.sub, mut errs)
				}
			}
			.namedmap {
				for nk, nv in v.as_map() {
					// every entry is a table of its own: a bare value would be read as an empty one,
					// silently (`range = { deg = 100 }` meaning the whole type's range)
					if nv !is map[string]toml.Any {
						errs << '${t.label} "${name}": "${nk}" must be a table, got ${actual(nv)}'
						continue
					}
					s.check_table(nv.as_map(), key.sub, mut errs)
				}
			}
			.str_map {
				for fk, fv in v.as_map() {
					if fv !is string {
						errs << '${t.label} "${name}": field "${fk}" must be a string type (e.g. "u16"), got ${actual(fv)}'
					}
				}
			}
			.val_map {
				for fk, fv in v.as_map() {
					if fv !is i64 && fv !is bool {
						errs << '${t.label} "${name}": "${fk}" must be an integer or a bool, got ${actual(fv)}'
					}
				}
			}
			else {}
		}
	}
	for key in t.keys {
		if key.required && key.name !in m {
			errs << '${t.label}: missing required key "${key.name}"'
		}
	}
}

// unknown: the keys of `m` that table `ctx` does not name (a table-valued key passes where the
// table takes them) — for a reader that checks its own types and only wants the typos
pub fn (s Schema) unknown(m map[string]toml.Any, ctx string) []string {
	t := s.table(ctx)
	names := t.names()
	mut out := []string{}
	for name, v in m {
		if name in names || (t.table_keys != '' && v is map[string]toml.Any) {
			continue
		}
		out << name
	}
	return out
}

// type_ok reports whether v matches the expected Typ.
pub fn type_ok(v toml.Any, typ Typ) bool {
	return match typ {
		.str {
			v is string
		}
		.int {
			v is i64
		}
		.id {
			v is i64 || v is string
		}
		.boolean {
			v is bool
		}
		.arr {
			v is []toml.Any
		}
		.tbl, .namedmap, .str_map, .val_map {
			v is map[string]toml.Any
		}
		.str_arr {
			if v is []toml.Any {
				v.all(it is string)
			} else {
				false
			}
		}
		.id_range {
			if v is []toml.Any {
				v.len == 2 && v[0] is i64 && v[1] is i64
			} else {
				false
			}
		}
		.int_arr {
			if v is []toml.Any {
				v.all(it is i64)
			} else {
				false
			}
		}
	}
}

// type_name: how a Typ reads in an "expected …" message
pub fn type_name(typ Typ) string {
	return match typ {
		.str { 'a string' }
		.int { 'an integer' }
		.id { 'a CAN id (integer) or a bus.dbc message name (string)' }
		.boolean { 'a boolean' }
		.arr { 'an array of tables' }
		.tbl, .namedmap, .val_map { 'a table' }
		.str_arr { 'an array of strings' }
		.int_arr { 'an array of integers' }
		.id_range { 'an inclusive [lo, hi] pair of CAN ids' }
		.str_map { 'a table of string values' }
	}
}

// actual names the concrete type of v, for a "got ..." message.
pub fn actual(v toml.Any) string {
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
