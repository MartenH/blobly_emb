// loom2v's parameter codegen (docs/diagnostics.md §3.4, R7, #288): a [[param]] is a value an FB
// reads and never writes, fixed per vehicle — coded with 0x2E on the [[did]] that names it, kept in
// the NvM journal, read back with 0x22. comm/param is the runtime; this file is its wiring.
//
//   [[param]]
//   name    = "SteerLimit"
//   fields  = { deg = "u16" }          # 1..2 fields: bool, u8/u16/u32, i8/i16/i32
//   default = { deg = 360 }            # compiled in, in range: what an uncoded vehicle runs
//   range   = { deg = { min = 0, max = 360 } }   # optional per field; absent = the type's
//   apply   = "reset"                  # or "next_dispatch" (the default)
//
//   [[did]]
//   id    = 0x0110
//   param = "SteerLimit"               # the ONE binding: 0x2E codes it, 0x22 reads it back
//   write = { session = ["extended"], security = 1 }
//
// An FB reads it by naming it in a handler's `reads`, like any input — there is no `to`: the
// reads are the one statement of who consumes it. On a ThreadX target the comm thread is the one
// writer of each parameter's IOC cell (the rx-signal path's shape): it publishes the restored value
// before the kernel starts, and a coded one after the journal has accepted it.
module main

import toml
import comm.param
import tools.ecumodel

// ParamField is one field of a [[param]]: its V type, wire width, signedness, range and default.
struct ParamField {
	name   string
	typ    string
	width  int
	signed bool
	min    i64
	max    i64
	def    i64
}

// ParamCfg is one [[param]].
struct ParamCfg {
	name        string
	fields      []ParamField
	apply_reset bool
	nvm_id      u16 // a pinned block id (0 = derived)
mut:
	id  u16 // its journal block (derive_param_nvm)
	fp  u16 // its layout's fingerprint
	did int // the [[did]] that codes it
}

// param_type: a field type's wire width, signedness and natural bounds.
fn param_type(typ string) ?(int, bool, i64, i64) {
	return match typ {
		'bool' { 1, false, i64(0), i64(1) }
		'u8' { 1, false, i64(0), i64(255) }
		'u16' { 2, false, i64(0), i64(65535) }
		'u32' { 4, false, i64(0), i64(4294967295) }
		'i8' { 1, true, i64(-128), i64(127) }
		'i16' { 2, true, i64(-32768), i64(32767) }
		'i32' { 4, true, i64(-2147483648), i64(2147483647) }
		else { none }
	}
}

const param_keys = ['name', 'fields', 'default', 'range', 'apply', 'nvm_id']

fn parse_params(doc toml.Doc) []ParamCfg {
	mut out := []ParamCfg{}
	for pv in ecumodel.toml_arr(doc, 'param') {
		pm := pv.as_map()
		name := (pm['name'] or { toml.Any('') }).string()
		if name == '' {
			panic('loom2v: [[param]] needs a `name`')
		}
		for k, _ in pm {
			if k !in param_keys {
				panic('loom2v: [[param]] "${name}" has "${k}" — a parameter takes ${param_keys}')
			}
		}
		fm := (pm['fields'] or { toml.Any(map[string]toml.Any{}) }).as_map()
		if fm.len < 1 || fm.len > param.max_fields {
			panic('loom2v: [[param]] "${name}" has ${fm.len} fields — a parameter has 1..${param.max_fields} (it rides one {a, b} IOC cell to its FBs)')
		}
		dm := (pm['default'] or {
			panic('loom2v: [[param]] "${name}" needs a `default` for every field — what an uncoded vehicle runs is stated, never assumed')
		}).as_map()
		rm := (pm['range'] or { toml.Any(map[string]toml.Any{}) }).as_map()
		for k, _ in dm {
			if k !in fm {
				panic('loom2v: [[param]] "${name}" default names "${k}", which is not one of its fields')
			}
		}
		for k, _ in rm {
			if k !in fm {
				panic('loom2v: [[param]] "${name}" range names "${k}", which is not one of its fields')
			}
		}
		mut fields := []ParamField{}
		for fname, ftv in fm {
			typ := ftv.string()
			width, signed, tlo, thi := param_type(typ) or {
				panic('loom2v: [[param]] "${name}" field "${fname}" is "${typ}" — a parameter field is bool, u8, u16, u32, i8, i16 or i32')
			}
			mut lo := tlo
			mut hi := thi
			if r := rm[fname] {
				if typ == 'bool' {
					panic('loom2v: [[param]] "${name}" field "${fname}" is a bool — it has no range to narrow')
				}
				rr := r.as_map()
				for rk, _ in rr {
					if rk !in ['min', 'max'] {
						panic('loom2v: [[param]] "${name}" range "${fname}" has "${rk}" — a range is { min, max }')
					}
				}
				lo = (rr['min'] or { toml.Any(tlo) }).i64()
				hi = (rr['max'] or { toml.Any(thi) }).i64()
				if lo < tlo || hi > thi || lo > hi {
					panic('loom2v: [[param]] "${name}" field "${fname}" range ${lo}..${hi} is not inside ${typ}\'s ${tlo}..${thi}, or is empty')
				}
			}
			dv := dm[fname] or {
				panic('loom2v: [[param]] "${name}" default has no "${fname}" — every field states its default')
			}
			def := if typ == 'bool' {
				if dv !is bool {
					panic('loom2v: [[param]] "${name}" default "${fname}" must be true or false')
				}
				if dv.bool() { i64(1) } else { i64(0) }
			} else {
				if dv !is i64 {
					panic('loom2v: [[param]] "${name}" default "${fname}" must be an integer')
				}
				dv.i64()
			}
			if def < lo || def > hi {
				panic('loom2v: [[param]] "${name}" default ${fname} = ${def} is outside its range ${lo}..${hi}')
			}
			fields << ParamField{
				name:   fname
				typ:    typ
				width:  width
				signed: signed
				min:    lo
				max:    hi
				def:    def
			}
		}
		apply := (pm['apply'] or { toml.Any('next_dispatch') }).string()
		if apply !in ['next_dispatch', 'reset'] {
			panic('loom2v: [[param]] "${name}" apply = "${apply}" — "next_dispatch" (the FB\'s next dispatch after the write) or "reset" (the next start)')
		}
		pin := (pm['nvm_id'] or { toml.Any(0) }).int()
		if pin < 0 || pin > 65534 {
			panic('loom2v: [[param]] "${name}" nvm_id = ${pin} is out of range (0 = derived, 1..65534 = pin)')
		}
		if out.any(it.name == name) {
			panic('loom2v: [[param]] "${name}" is declared twice')
		}
		out << ParamCfg{
			name:        name
			fields:      fields
			apply_reset: apply == 'reset'
			nvm_id:      u16(pin)
		}
	}
	if out.len > param.max_params {
		panic('loom2v: ${out.len} [[param]]s — a node holds at most ${param.max_params} (comm/param max_params)')
	}
	return out
}

// param_ident: a parameter's LAYOUT — name, then each field's name and type in declaration order,
// the order the record and the cell carry them. Its block id and fingerprint both hash it; the
// range is not in it (comm/param: a stored value is revalidated against the range instead).
fn param_ident(p ParamCfg) string {
	return '${p.name}:${p.fields.map('${it.name}=${it.typ}').join(',')}'
}

fn (p ParamCfg) width() int {
	mut w := 0
	for f in p.fields {
		w += f.width
	}
	return w
}

// param_of: the [[param]] named `name`, or none.
fn param_of(m Model, name string) ?ParamCfg {
	for p in m.params {
		if p.name == name {
			return p
		}
	}
	return none
}

fn is_param(m Model, name string) bool {
	return m.params.any(it.name == name)
}

// validate_params: where a parameter can live, who codes it and who reads it.
fn validate_params(mut m Model, doc toml.Doc) {
	status := m.dids.filter(it.param_status)
	if status.len > 1 {
		panic('loom2v: ${status.len} [[did]]s are the parameter status — one says it for every parameter')
	}
	if m.params.len == 0 {
		if m.dids.any(it.param != '') || status.len > 0 {
			panic('loom2v: a [[did]] names a parameter, but the node declares no [[param]]')
		}
		return
	}
	if !m.target.threadx {
		panic('loom2v: [[param]] is generated for a ThreadX target: a parameter lives in the NvM journal, which only the target generates (docs/diagnostics.md §3.4)')
	}
	if !m.nvm.on {
		panic('loom2v: [[param]] needs [nvm] — a coded value is kept in the NvM journal across resets and power loss')
	}
	if m.isotp_conns.len == 0 {
		panic('loom2v: [[param]] is coded with 0x2E — declare the diagnostic server\'s [isotp] connection')
	}
	for i, p in m.params {
		if p.name in m.sig_of {
			panic('loom2v: [[param]] "${p.name}" is also a [[signal]] — one name, one input')
		}
		dids := m.dids.filter(it.param == p.name)
		if dids.len != 1 {
			panic('loom2v: [[param]] "${p.name}" is coded through ${dids.len} [[did]]s — exactly one names it (`param = "${p.name}"`): a parameter nobody can write is a constant, and two DIDs are two answers')
		}
		m.params[i].did = dids[0].id
	}
	for d in m.dids {
		if d.param != '' && !is_param(m, d.param) {
			panic('loom2v: [[did]] 0x${d.id.hex()} names parameter "${d.param}", which is not a [[param]]')
		}
	}
	// who reads it: FB handlers on this image, all on one thread (the cell has one reader context),
	// and nobody writes it
	mut reader_thr := map[string]string{}
	for fb in ecumodel.toml_arr(doc, 'fb') {
		fm := fb.as_map()
		fbname := (fm['name'] or { toml.Any('') }).string()
		thr := m.part.fb_thread[fbname] or { '' }
		part := m.part.thread_part[thr] or { '' }
		for h in (fm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			hm := h.as_map()
			for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
				if is_param(m, w.string()) {
					panic('loom2v: fb "${fbname}" writes parameter "${w.string()}" — a parameter is read-only to FBs; a tester codes it (0x2E)')
				}
			}
			for r in (hm['reads'] or { toml.Any([]toml.Any{}) }).array() {
				if !is_param(m, r.string()) {
					continue
				}
				if m.part.external[part] or { false } {
					panic('loom2v: fb "${fbname}" reads parameter "${r.string()}" from partition "${part}", whose image is built elsewhere — a parameter reaches FBs on the image that owns the journal')
				}
				if prev := reader_thr[r.string()] {
					if prev != thr {
						panic('loom2v: parameter "${r.string()}" is read on threads "${prev}" and "${thr}" — its cell has one reader context; read it on one thread')
					}
				}
				reader_thr[r.string()] = thr
			}
		}
	}
	for p in m.params {
		if p.name !in reader_thr {
			panic('loom2v: [[param]] "${p.name}" is read by no FB handler — a parameter nothing reads codes nothing; add it to a handler\'s `reads`')
		}
	}
}

// derive_param_nvm: each parameter's journal block and fingerprint, refused on a collision with
// any other block (naming the pin that resolves it), and the journal capacity with them in it.
fn derive_param_nvm(mut m Model) {
	if m.params.len == 0 {
		return
	}
	mut used := map[u16]string{}
	for sname, id in m.nvm_ids {
		used[id] = 'persistent signal "${sname}"'
	}
	if fault_persist_on(m) {
		used[m.fault_status_id] = 'the fault memory status'
		for k, id in m.fault_snap_ids {
			if id != 0 {
				used[id] = 'a snapshot block of [[fault]] "${m.faults[k].name}"'
				used[m.fault_snap_ids_b[k]] = 'a snapshot block of [[fault]] "${m.faults[k].name}"'
			}
		}
	}
	for i, p in m.params {
		ident := param_ident(p)
		id := if p.nvm_id != 0 { p.nvm_id } else { nvm_hash16('param:${ident}') }
		if prev := used[id] {
			panic('loom2v: [[param]] "${p.name}": its journal block 0x${id.hex()} collides with ${prev} — pin one side (`nvm_id = <1..65534>` on the parameter or the signal) and keep the pin')
		}
		used[id] = '[[param]] "${p.name}"'
		m.params[i].id = id
		m.params[i].fp = nvm_hash16('param-schema:${ident}')
	}
	snaps := m.fault_snap_ids.filter(it != 0).len
	if m.nvm_names.len + 1 + 2 * snaps + m.params.len > 48 {
		panic('loom2v: ${m.nvm_names.len} persistent signals, the fault memory and ${m.params.len} parameters exceed the safe journal pool budget (48 of nvm.max_blocks)')
	}
	// capacity, the docs/nvm.md headroom rule: one record per parameter in the live set, and its
	// full rewrite beside it, within one sector
	live := m.nvm_names.len + fault_live_records(m) + m.params.len + 1
	if live + live > int(m.nvm.sector_records) {
		panic('loom2v: the journal needs ${live + live} records of sector headroom (live set ${live}, ${m.params.len} parameters included) but [nvm] sector_records = ${m.nvm.sector_records}')
	}
}

// --- emitted fragments ---------------------------------------------------------

// param_sig_structs: each parameter's value type in the `sig` module, as a signal's is.
fn param_sig_structs(m Model) []string {
	mut g := []string{}
	for p in m.params {
		g << ''
		g << '// parameter (docs/diagnostics.md §3.4): coded with 0x2E on DID 0x${p.did.hex()}, read-only to FBs'
		g << 'pub struct ${p.name} {'
		g << 'pub mut:'
		for f in p.fields {
			g << '\t${f.name} ${f.typ}'
		}
		g << '}'
	}
	return g
}

// param_read_lines: a handler's read of parameter `p` from its cell `idx` — every field, as the
// comm thread published it (field 0 in a, field 1 in b, two's complement).
fn param_read_lines(p ParamCfg, idx int) []string {
	v := snake(p.name)
	mut g := ['\tmut ${v}_a := u32(0)', '\tmut ${v}_b := u32(0)',
		'\tC.ioc_get(${idx}, &${v}_a, &${v}_b) // parameter: the comm thread publishes it']
	for i, f in p.fields {
		src := if i == 0 { '${v}_a' } else { '${v}_b' }
		g << if f.typ == 'bool' {
			'\tinp.${v}.${snake(f.name)} = ${src} != 0'
		} else {
			'\tinp.${v}.${snake(f.name)} = ${f.typ}(${src})'
		}
	}
	return g
}

fn param_globals(m Model) []string {
	if m.params.len == 0 {
		return []string{}
	}
	return ['\tg_param param.Params // the parameters: the comm thread is their one writer (restored pre-kernel)']
}

// param_fns: the journal seam and the publish into each parameter's FB cell.
fn param_fns(m Model, ioc_idx map[string]int) []string {
	if m.params.len == 0 {
		return []string{}
	}
	mut g := [
		'',
		'fn param_put(ctx voidptr, id u16, data &u8, len u16) bool {',
		'\treturn g_nvm.put(id, data, len)',
		'}',
		'',
		'fn param_get(ctx voidptr, id u16, out &u8, cap u16) u16 {',
		'\treturn g_nvm.get(id, out, cap)',
		'}',
		'',
		'fn param_pub(ctx voidptr, i int, a u32, b u32) {',
		'\tmatch i {',
	]
	for i, p in m.params {
		g << '\t\t${i} { C.ioc_pub(${ioc_idx[p.name] or { panic('loom2v: parameter "${p.name}" has no IOC cell') }}, a, b) } // ${p.name}'
	}
	g << '\t\telse {}'
	g << '\t}'
	g << '}'
	return g
}

// param_config_lines: the table configured, in boot() before the restore.
fn param_config_lines(m Model) []string {
	mut g := []string{}
	for i, p in m.params {
		g << '\tg_param.p[${i}].did = u16(0x${p.did.hex()}) // ${p.name}'
		g << '\tg_param.p[${i}].id = u16(0x${p.id.hex()})'
		g << '\tg_param.p[${i}].fp = u16(0x${p.fp.hex()})'
		g << '\tg_param.p[${i}].nfields = ${p.fields.len}'
		if p.apply_reset {
			g << '\tg_param.p[${i}].apply_reset = true // takes effect at the next start'
		}
		for k, f in p.fields {
			g << '\tg_param.p[${i}].fields[${k}] = param.Field{ // ${f.name} ${f.typ}'
			g << '\t\twidth:  ${f.width}'
			if f.signed {
				g << '\t\tsigned: true'
			}
			g << '\t\tmin:    i64(${f.min})'
			g << '\t\tmax:    i64(${f.max})'
			g << '\t\tdef:    i64(${f.def})'
			g << '\t}'
		}
	}
	g << '\tg_param.n = ${m.params.len}'
	g << '\tg_param.store = param.Store{'
	g << '\t\tput: param_put'
	g << '\t\tget: param_get'
	g << '\t}'
	g << '\tg_param.publish = param_pub'
	return g
}

// param_boot_lines: after the journal's mount and prune, before the kernel: every parameter read
// back, revalidated, and published into its FBs' cell — the first dispatch reads it.
fn param_boot_lines(m Model) []string {
	if m.params.len == 0 {
		return []string{}
	}
	mut g := ['\t// [[param]]: restored before any FB dispatches (docs/diagnostics.md §3.4)']
	g << param_config_lines(m)
	g << '\tg_param.restore(g_nvm.mounted)'
	return g
}

// param_bind_lines: on the comm thread, once every DID is in the server: the parameter DIDs
// filled and bound (0x2E goes through comm/param), the status DID filled.
fn param_bind_lines(m Model) []string {
	if m.params.len == 0 {
		return []string{}
	}
	st := m.dids.filter(it.param_status)
	sid := if st.len > 0 { st[0].id } else { 0 }
	return ['\tg_param.bind(mut g_diag.server, u16(0x${sid.hex()})) // the parameter DIDs: 0x2E codes, 0x22 reads back']
}

// param_sleep_lines: a parameter coded while the bus sleeps re-runs the flush choreography, so the
// clean marker never sits below a record it does not cover (REQ-NVM-014) — an NM node's.
fn param_sleep_lines(m Model, ioc_idx map[string]int) []string {
	if m.params.len == 0 || !m.nm.on {
		return []string{}
	}
	mut g := ['\t\tif g_param.take_wrote() && g_nm.state() == .bus_sleep {']
	g << nvm_flush_choreo(m, ioc_idx, '\t\t\t')
	g << '\t\t}'
	return g
}

// param_did_len: the record length of a parameter DID or the status DID (0 = neither).
fn param_did_len(m Model, d DidCfg) int {
	if d.param_status {
		return m.params.len
	}
	if p := param_of(m, d.param) {
		return p.width()
	}
	return 0
}

fn param_manifest(m Model) []string {
	if m.params.len == 0 {
		return []string{}
	}
	mut g := ['# params: name,did,block,apply,fields (name:type:min..max=default)']
	for p in m.params {
		fs := p.fields.map('${it.name}:${it.typ}:${it.min}..${it.max}=${it.def}').join(' ')
		g << '${p.name},0x${p.did.hex()},0x${p.id.hex()},${if p.apply_reset { 'reset' } else { 'next_dispatch' }},${fs}'
	}
	return g
}
