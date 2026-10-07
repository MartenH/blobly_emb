module cfgschema

import strings

// ---- docs/config-reference.md ----
const md_header = '# Configuration reference

<!-- GENERATED from tools/cfgschema by tools/cfgdoc — do not edit. `make config-docs` regenerates
this file and schema/*.schema.json; `make check` fails when either is stale. -->

Every table and key of the two configuration files, generated from the ONE schema the tools
validate against (`tools/cfgschema`): `ecucheck` refuses an unknown key, a wrong type or a missing
required key from it, and the range and enumeration checks read their bounds from it. What a key
MEANS beyond one line — and the rules that relate keys to each other, which no single row can
state — is in the docs each section links to: [architecture.md](architecture.md),
[multi-node.md](multi-node.md), [diagnostics.md](diagnostics.md), [communication.md](communication.md).

- **ecu.toml** — one ECU (a node): its partitions, threads, Function Blocks, signals, buses and
  services. A node of a dissolved system authors only its internals; `sysgen` writes the complete
  file as `gen-<node>.toml`, which is an ecu.toml and validates against the same schema.
- **system.toml** — a system of ECUs: the buses, the cross-node signals and frames, the routes and
  each node\'s identities (docs/multi-node.md).

Editors: `.taplo.toml` maps both files (and `gen-*.toml`) to the JSON Schemas in `schema/`, so
Even Better TOML / Taplo complete keys, show these descriptions on hover and validate as you type.

A default of "—" means the key has no single default: it is required, or what its absence means is
in its description. Integer ranges are inclusive.
'

// markdown renders both schemas as one reference document
pub fn markdown(schemas []Schema) string {
	mut b := strings.new_builder(64 * 1024)
	b.write_string(md_header)
	for s in schemas {
		b.write_string('\n## ${s.file}\n\n${s.desc}\n')
		for t in s.ordered() {
			b.write_string('\n<a id="${anchor(s, t.ctx)}"></a>\n\n### `${t.label}`\n\n')
			if t.desc != '' {
				b.write_string('${t.desc}\n\n')
			}
			if t.table_keys != '' {
				b.write_string('Any other key holding a table is read as ${link(s, t.table_keys)}.\n\n')
			}
			b.write_string('| key | type | required | default | allowed | description |\n')
			b.write_string('|---|---|---|---|---|---|\n')
			for key in t.keys {
				typ := if key.sub != '' {
					'${type_word(key.typ)} → ${link(s, key.sub)}'
				} else {
					type_word(key.typ)
				}
				reqd := if key.required { 'yes' } else { '' }
				def := if key.def == '' { '—' } else { '`${key.def}`' }
				b.write_string('| `${key.name}` | ${typ} | ${reqd} | ${md_escape(def)} | ${md_escape(allowed(key))} | ${md_escape(key.desc)} |\n')
			}
		}
	}
	return b.str()
}

// ordered: the tables in reading order — the root, then depth-first in the order keys name them
// (a table nothing names comes last, so nothing is ever left out of the document)
pub fn (s Schema) ordered() []Table {
	mut seen := map[string]bool{}
	mut out := []Table{}
	s.visit(s.root, mut seen, mut out)
	for t in s.tables {
		if t.ctx !in seen {
			s.visit(t.ctx, mut seen, mut out)
		}
	}
	return out
}

fn (s Schema) visit(ctx string, mut seen map[string]bool, mut out []Table) {
	if ctx == '' || ctx in seen || !s.has_table(ctx) {
		return
	}
	seen[ctx] = true
	t := s.table(ctx)
	out << t
	for key in t.keys {
		s.visit(key.sub, mut seen, mut out)
	}
	s.visit(t.table_keys, mut seen, mut out)
}

fn anchor(s Schema, ctx string) string {
	return '${s.file.all_before('.')}-${ctx.replace('_', '-')}'
}

fn link(s Schema, ctx string) string {
	return '[`${s.table(ctx).label}`](#${anchor(s, ctx)})'
}

fn type_word(t Typ) string {
	return match t {
		.str { 'string' }
		.int { 'integer' }
		.boolean { 'boolean' }
		.arr { 'array of tables' }
		.tbl { 'table' }
		.str_arr { 'array of strings' }
		.int_arr { 'array of integers' }
		.id_range { '[lo, hi] of integers' }
		.namedmap { 'tables by name' }
		.str_map { 'table of strings' }
		.val_map { 'table of integers / booleans' }
		.id { 'CAN id or DBC message name' }
	}
}

// allowed: the enumeration, or the range, as the reference states it
pub fn allowed(k Key) string {
	if k.choices.len > 0 {
		return k.choices.map('`"${it}"`').join(', ')
	}
	if k.open_max {
		return '>= ${k.min}'
	}
	if k.ranged {
		return '${num(k, k.min)}..${num(k, k.max)}'
	}
	return ''
}

// num: an integer bound in the base its field is written in (an id or an address in hex)
fn num(k Key, v i64) string {
	if k.max > 0xFF && hexish(k.max) {
		return '0x${v:X}'
	}
	return '${v}'
}

// hexish: a bound that is a run of ones or ends in F (0x7FF, 0xFFFF, 0xEFFF) — an id or an
// address, written in hex; a decimal limit (1000000, 4096) is written as it is
fn hexish(v i64) bool {
	return (v & (v + 1)) == 0 || (v & 0xF) == 0xF || (v & 0xF) == 0xE
}

fn md_escape(s string) string {
	return s.replace('|', '\\|')
}

// ---- schema/*.schema.json (JSON Schema draft-07, for Taplo / Even Better TOML) ----

// json_schema renders one schema as a JSON Schema document. Every table is a closed object
// (additionalProperties false) whose properties carry the description, the default, the
// enumeration and the range, so an editor completes keys, explains them on hover and flags a typo.
pub fn (s Schema) json_schema() string {
	mut b := strings.new_builder(64 * 1024)
	b.write_string('{\n')
	b.write_string('  "\$schema": "http://json-schema.org/draft-07/schema#",\n')
	b.write_string('  "\$comment": "GENERATED from tools/cfgschema by tools/cfgdoc - do not edit; make config-docs regenerates it",\n')
	b.write_string('  "title": ${jstr(s.file)},\n')
	b.write_string('  "description": ${jstr(s.title)},\n')
	s.object_body(s.table(s.root), mut b, '  ')
	b.write_string(',\n  "definitions": {')
	mut first := true
	for t in s.ordered() {
		if t.ctx == s.root {
			continue
		}
		b.write_string(if first { '\n' } else { ',\n' })
		first = false
		b.write_string('    ${jstr(t.ctx)}: {\n')
		b.write_string('      "title": ${jstr(t.label)},\n')
		if t.desc != '' {
			b.write_string('      "description": ${jstr(t.desc)},\n')
		}
		s.object_body(t, mut b, '      ')
		b.write_string('\n    }')
	}
	b.write_string('\n  }\n}\n')
	return b.str()
}

// object_body: "type", "properties", "required", "additionalProperties" of one table, no braces
fn (s Schema) object_body(t Table, mut b strings.Builder, ind string) {
	b.write_string('${ind}"type": "object",\n${ind}"properties": {')
	for i, key in t.keys {
		b.write_string(if i == 0 { '\n' } else { ',\n' })
		b.write_string('${ind}  ${jstr(key.name)}: ${key_json(key)}')
	}
	b.write_string('\n${ind}}')
	reqd := t.keys.filter(it.required).map(jstr(it.name))
	if reqd.len > 0 {
		b.write_string(',\n${ind}"required": [${reqd.join(', ')}]')
	}
	if t.table_keys != '' {
		b.write_string(',\n${ind}"additionalProperties": ${ref(t.table_keys)}')
	} else {
		b.write_string(',\n${ind}"additionalProperties": false')
	}
}

fn ref(ctx string) string {
	return '{"\$ref": "#/definitions/${ctx}"}'
}

// key_json: one property, on one line
fn key_json(k Key) string {
	mut f := []string{}
	mut desc := k.desc
	if k.def != '' {
		desc += if desc == '' { 'Default: ${k.def}.' } else { ' Default: ${k.def}.' }
	}
	match k.typ {
		.str {
			f << '"type": "string"'
			if k.choices.len > 0 {
				f << '"enum": [${k.choices.map(jstr(it)).join(', ')}]'
			}
		}
		.int {
			f << '"type": "integer"'
			f << bounds(k)
		}
		.boolean {
			f << '"type": "boolean"'
		}
		.arr {
			f << '"type": "array"'
			f << '"items": ${ref(k.sub)}'
		}
		.tbl {
			f << '"\$ref": "#/definitions/${k.sub}"'
		}
		.str_arr {
			f << '"type": "array"'
			if k.choices.len > 0 {
				f << '"items": {"type": "string", "enum": [${k.choices.map(jstr(it)).join(', ')}]}'
			} else {
				f << '"items": {"type": "string"}'
			}
		}
		.int_arr {
			f << '"type": "array"'
			inner := ['"type": "integer"'].filter(it != '')
			mut items := inner.clone()
			items << bounds(k)
			f << '"items": {${items.filter(it != '').join(', ')}}'
		}
		.id_range {
			f << '"type": "array"'
			f << '"items": {"type": "integer"}'
			f << '"minItems": 2'
			f << '"maxItems": 2'
		}
		.namedmap {
			f << '"type": "object"'
			f << '"additionalProperties": ${ref(k.sub)}'
		}
		.str_map {
			f << '"type": "object"'
			f << '"additionalProperties": {"type": "string"}'
		}
		.val_map {
			f << '"type": "object"'
			f << '"additionalProperties": {"type": ["integer", "boolean"]}'
		}
		.id {
			f << '"type": ["integer", "string"]'
			f << bounds(k)
		}
	}
	if jd := json_default(k) {
		f << '"default": ${jd}'
	}
	if desc != '' {
		f << '"description": ${jstr(desc)}'
	}
	return '{${f.filter(it != '').join(', ')}}'
}

fn bounds(k Key) string {
	if !k.ranged {
		return ''
	}
	if k.open_max {
		return '"minimum": ${k.min}'
	}
	return '"minimum": ${k.min}, "maximum": ${k.max}'
}

// json_default: the default as a JSON value, where it is one (a string, a boolean, an integer)
fn json_default(k Key) ?string {
	d := k.def
	if d == '' {
		return none
	}
	if d.starts_with('"') && d.ends_with('"') && d.len >= 2 {
		return jstr(d[1..d.len - 1])
	}
	if d == 'true' || d == 'false' {
		return d
	}
	if d.starts_with('0x') {
		v := d[2..].replace('_', '')
		if v != '' && v.bytes().all(it.is_hex_digit()) {
			return '${('0x' + v).i64()}'
		}
		return none
	}
	clean := d.replace('_', '')
	if clean != '' && (clean.bytes().all(it.is_digit()) || (clean[0] == `-` && clean.len > 1 && clean[1..].bytes().all(it.is_digit()))) {
		return clean
	}
	return none
}

// jstr: a JSON string literal
fn jstr(s string) string {
	mut b := strings.new_builder(s.len + 2)
	b.write_u8(`"`)
	for c in s {
		match c {
			`"` { b.write_string('\\"') }
			`\\` { b.write_string('\\\\') }
			`\n` { b.write_string('\\n') }
			`\t` { b.write_string('\\t') }
			else { b.write_u8(c) }
		}
	}
	b.write_u8(`"`)
	return b.str()
}
