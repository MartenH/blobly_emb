// loom2v's persistence codegen (docs/nvm.md P2, "the toml part"): a signal with
// `persist = "now" | "shutdown"` is restored before the application's first
// activation and journaled by the platform afterwards — the FB cannot tell.
//
//   [nvm]
//   min_write_ms   = 1000   # the ONE system write floor ("now" pacing)
//   sector_records = 4096   # journal geometry, for the generation-time checks
//   endurance      = 10000  # flash erase cycles (wear math)
//   min_years      = 10     # required wear lifetime at worst-case write rates
//
// What the generator owns (nothing of this exists at runtime as config):
//   - SCHEMA IDENTITY: each persistent signal's block id = a 16-bit FNV hash of
//     name + field names + types (insert/reorder/rename safe; any layout change
//     = new identity = declared default). Collisions fail generation with an
//     `nvm_id = N` pin suggestion.
//   - the WEAR CHECK (REQ-NVM-010): worst-case records/hour from each writer's
//     period vs the floor, against sector geometry + endurance — a config that
//     cannot survive `min_years` fails generation with the math.
//   - the emitted wiring: journal mount + prune + restore staging BEFORE the
//     kernel starts (single-threaded window), per-thread cell restore, wrapper
//     staging through intra-core IOC cells (single-writer, wait-free, proven),
//     and the comm-thread service (change+floor-gated puts; the NM
//     prepare-bus-sleep edge flushes everything, marks clean, and runs the
//     deferred erase in the quiet window).
//
// P2 cut: persistent signals are LOCAL (written and read on one thread) with
// 1..2 unsigned fields (<= 8 packed bytes — they stage through one ioc cell).
// Wider/chained persistent signals arrive with a seqlock stage; the JOURNAL
// already handles chains (platform blocks use them today).
module main

import toml
import tools.ecumodel

struct NvmCfg {
mut:
	on             bool
	min_write_ms   u32 = 1000
	sector_records u32 = 4096
	endurance      u32 = 10000
	min_years      u32 = 10
}

const nvm_keys = ['enabled', 'min_write_ms', 'sector_records', 'endurance', 'min_years']

fn parse_nvm(doc toml.Doc) NvmCfg {
	mut t := NvmCfg{}
	ncfg := doc.value_opt('nvm') or { return t }
	nm := ncfg.as_map()
	for k, _ in nm {
		if k !in nvm_keys {
			panic('loom2v: [nvm] unknown key "${k}" (allowed: ${nvm_keys})')
		}
	}
	t.on = (nm['enabled'] or { toml.Any(true) }).bool()
	t.min_write_ms = u32((nm['min_write_ms'] or { toml.Any(1000) }).int())
	t.sector_records = u32((nm['sector_records'] or { toml.Any(4096) }).int())
	t.endurance = u32((nm['endurance'] or { toml.Any(10000) }).int())
	t.min_years = u32((nm['min_years'] or { toml.Any(10) }).int())
	return t
}

// field_width: packed bytes of one signal field (persist supports unsigned scalars).
fn field_width(typ string) int {
	return match typ {
		'u8' { 1 }
		'u16' { 2 }
		'u32' { 4 }
		else { 0 }
	}
}

fn (si SigInfo) packed_size() int {
	mut n := 0
	for f in si.fields {
		n += field_width(f.typ)
	}
	return n
}

// nvm_hash16: FNV-1a over the schema identity string, folded to 16 bits and
// kept off the reserved values (0 = marker, 0xFFFF = erased-like).
fn nvm_hash16(ident string) u16 {
	mut h := u32(0x811C_9DC5)
	for b in ident.bytes() {
		h ^= u32(b)
		h *= 16777619
	}
	mut id := u16((h & 0xFFFF) ^ (h >> 16))
	if id == 0 || id == 0xFFFF {
		id = 1
	}
	return id
}

// derive_nvm validates every persistent signal and assigns identities. Returns
// (ordered names, name -> id). Panics with actionable messages — all of this
// is generation-time (REQ-NVM-010: wear provable at configuration time).
fn derive_nvm(mut m Model, doc toml.Doc) ([]string, map[string]u16) {
	mut names := []string{}
	mut ids := map[string]u16{}
	for sname in m.sig_names {
		si := m.sig_of[sname] or { continue }
		if si.persist == '' {
			continue
		}
		if si.persist !in ['now', 'shutdown'] {
			panic('loom2v: signal "${sname}" persist = "${si.persist}" — the policy is ' +
				'"now" (floored write-through) or "shutdown" (sleep-flush only), an INTENT, ' +
				'not a tuning number (docs/nvm.md)')
		}
		if !m.nvm.on {
			panic('loom2v: signal "${sname}" is persistent but there is no [nvm] block — ' +
				'declare the storage (min_write_ms, sector geometry) first')
		}
		if !si.local {
			panic('loom2v: persistent signal "${sname}" is not thread-local (from "${si.from}" ' +
				'to "${si.to}") — P2 persists local signals; bus/cross-core persistence is not designed')
		}
		if si.has_valid {
			panic('loom2v: persistent signal "${sname}" has a `valid` field — persistence ' +
				'restores VALUES; freshness is not a stored property')
		}
		if si.fields.len < 1 || si.fields.len > 2 {
			panic('loom2v: persistent signal "${sname}" has ${si.fields.len} fields — the P2 ' +
				'staging cell carries 1..2 unsigned fields (split the signal, or wait for the ' +
				'wide-persist phase)')
		}
		for f in si.fields {
			if field_width(f.typ) == 0 {
				panic('loom2v: persistent signal "${sname}" field "${f.name}" is ${f.typ} — ' +
					'persist supports unsigned scalar fields (u8/u16/u32)')
			}
		}
		id := if si.nvm_id != 0 {
			si.nvm_id
		} else {
			nvm_hash16('${sname}:${si.fields.map('${it.name}=${it.typ}').join(',')}')
		}
		for other, oid in ids {
			if oid == id {
				panic('loom2v: persistent signals "${other}" and "${sname}" collide on nvm id ' +
					'0x${id.hex()} — pin one explicitly with `nvm_id = <1..65534>`')
			}
		}
		ids[sname] = id
		names << sname
	}
	if names.len == 0 {
		return names, ids
	}
	// capacity + GLOBAL REWRITE HEADROOM, mirroring the engine's runtime gate:
	// every persistent signal is one record (P2 <= 8 B), live = n + marker.
	live := u32(names.len) + 1
	if live + 1 > m.nvm.sector_records {
		panic('loom2v: ${names.len} persistent signals + the marker exceed the sector ' +
			'(${m.nvm.sector_records} records) — grow the sectors or persist less')
	}
	// WEAR (REQ-NVM-010): worst case, every "now" signal writes at its writer's
	// activation rate, floored by min_write_ms. Records/hour fill sectors;
	// each fill costs one erase of the pair's cycle budget.
	mut recs_per_hour := f64(0)
	for sname in names {
		si := m.sig_of[sname] or { continue }
		if si.persist != 'now' {
			continue
		}
		period_ms := writer_period_ms(doc, sname)
		mut eff := period_ms
		if eff < m.nvm.min_write_ms {
			eff = m.nvm.min_write_ms
		}
		recs_per_hour += 3600_000.0 / f64(eff)
	}
	if recs_per_hour > 0 {
		fills_per_hour := recs_per_hour / f64(m.nvm.sector_records)
		years := f64(m.nvm.endurance) / (fills_per_hour * 24.0 * 365.0)
		if years < f64(m.nvm.min_years) {
			panic('loom2v: [nvm] wear check failed — worst case ${recs_per_hour:.0} records/h ' +
				'fills a ${m.nvm.sector_records}-record sector ${fills_per_hour:.2}x/h; at ' +
				'${m.nvm.endurance} cycles that is ${years:.1} years < min_years ${m.nvm.min_years}. ' +
				'Raise min_write_ms, grow the sectors, or persist fewer "now" signals.')
		}
	}
	return names, ids
}

// writer_period_ms: the activation period of the handler that WRITES a signal
// (validated single-writer elsewhere); 0 = not found (treated as floor-paced).
fn writer_period_ms(doc toml.Doc, sname string) u32 {
	for fb in ecumodel.toml_arr(doc, 'fb') {
		for h in (fb.as_map()['handler'] or { toml.Any([]toml.Any{}) }).array() {
			hm := h.as_map()
			for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
				if w.string() == sname {
					return u32((hm['period_ms'] or { toml.Any(0) }).int())
				}
			}
		}
	}
	return 0
}

fn nvm_on(m Model) bool {
	return m.nvm.on && m.nvm_names.len > 0
}

// --- emitted fragments ---------------------------------------------------------

fn nvm_c_decls(m Model) []string {
	if !nvm_on(m) {
		return []string{}
	}
	return [
		'// [nvm]: the journal storage map + flash driver (boards layer / example glue)',
		'fn C.nvm_map_a() u32',
		'fn C.nvm_map_b() u32',
		'fn C.nvm_map_size() u32',
		'fn C.bflash_erase(addr u32, size u32) int',
		'fn C.bflash_program(addr u32, data &u8, len u32) int',
		'fn C.bflash_read(addr u32, out &u8, len u32) int',
	]
}

fn nvm_globals(m Model) []string {
	if !nvm_on(m) {
		return []string{}
	}
	mut g := ['\tg_nvm nvm.Journal // the persistence journal (mounted pre-kernel)']
	for sname in m.nvm_names {
		g << '\tg_nvmres_${snake(sname)} [8]u8 // restore staging (pre-kernel -> thread init)'
		g << '\tg_nvmres_${snake(sname)}_n u16'
	}
	return g
}

// nvm_flash_wrappers: V-side FlashOps hooks over the boards flash driver.
fn nvm_flash_wrappers(m Model) []string {
	if !nvm_on(m) {
		return []string{}
	}
	return [
		'',
		'fn nvm_fl_erase(ctx voidptr, addr u32, size u32) bool {',
		'\treturn C.bflash_erase(addr, size) != 0',
		'}',
		'',
		'fn nvm_fl_program(ctx voidptr, addr u32, data &u8, len u32) bool {',
		'\treturn C.bflash_program(addr, data, len) != 0',
		'}',
		'',
		'fn nvm_fl_read(ctx voidptr, addr u32, out &u8, len u32) bool {',
		'\treturn C.bflash_read(addr, out, len) != 0',
		'}',
	]
}

// nvm_boot_lines: mount + prune + restore, in boot() BEFORE the kernel starts —
// the single-threaded window, so the journal's one-thread contract holds by
// construction (ownership then passes to the comm thread).
fn nvm_boot_lines(m Model, ioc_idx map[string]int) []string {
	if !nvm_on(m) {
		return []string{}
	}
	mut g := []string{}
	g << '\t// [nvm]: mount + restore BEFORE the kernel — the single-threaded window.'
	g << '\t// Restored values seed both the thread-init staging AND the persist ioc'
	g << '\t// cells (so the comm service sees no phantom change on the first pass).'
	g << '\tg_nvm.ops = bootfl.FlashOps{'
	g << '\t\terase:   nvm_fl_erase'
	g << '\t\tprogram: nvm_fl_program'
	g << '\t\tread:    nvm_fl_read'
	g << '\t}'
	g << '\tg_nvm.cfg = nvm.SectorCfg{'
	g << '\t\ta_addr: C.nvm_map_a()'
	g << '\t\tb_addr: C.nvm_map_b()'
	g << '\t\tsize:   C.nvm_map_size()'
	g << '\t}'
	g << '\tif g_nvm.mount() {'
	mut keep := []string{}
	for sname in m.nvm_names {
		keep << 'u16(${m.nvm_ids[sname] or { 0 }})'
	}
	g << '\t\tkeep := [${keep.join(', ')}]!'
	g << '\t\tg_nvm.prune(&keep[0], ${m.nvm_names.len})'
	for sname in m.nvm_names {
		si := m.sig_of[sname] or { continue }
		id := m.nvm_ids[sname] or { 0 }
		n := snake(sname)
		packed := si.packed_size()
		cell := ioc_idx[sname] or { 0 }
		g << '\t\tif g_nvm.get(${id}, &g_nvmres_${n}[0], 8) == ${packed} {'
		g << '\t\t\tg_nvmres_${n}_n = ${packed}'
		g << '\t\t\tC.ioc_pub(${cell}, ${nvm_unpack_expr(si, 0, 'g_nvmres_${n}')}, ${nvm_unpack_expr(si,
			1, 'g_nvmres_${n}')})'
		g << '\t\t}'
	}
	g << '\t}'
	return g
}

// nvm_unpack_expr: the u32 value of field `idx` from a packed staging buffer.
fn nvm_unpack_expr(si SigInfo, idx int, buf string) string {
	if idx >= si.fields.len {
		return 'u32(0)'
	}
	mut off := 0
	for i in 0 .. idx {
		off += field_width(si.fields[i].typ)
	}
	w := field_width(si.fields[idx].typ)
	mut terms := []string{}
	for b in 0 .. w {
		if b == 0 {
			terms << 'u32(${buf}[${off}])'
		} else {
			terms << '(u32(${buf}[${off + b}]) << ${8 * b})'
		}
	}
	return terms.join(' | ')
}

// nvm_restore_lines: seed a thread's local cells from the staging buffers —
// the FIRST activation reads the stored value (REQ-NVM-001).
fn nvm_restore_lines(m Model, sig_writer_thr map[string]string, thr string, multi bool) []string {
	if !nvm_on(m) {
		return []string{}
	}
	mut g := []string{}
	for sname in m.nvm_names {
		si := m.sig_of[sname] or { continue }
		owner := sig_writer_thr[sname] or { '' }
		if multi && owner != thr {
			continue
		}
		n := snake(sname)
		g << '\tif g_nvmres_${n}_n == ${si.packed_size()} { // restored before first dispatch'
		for fi, f in si.fields {
			g << '\t\tst.cell_${n}.${snake(f.name)} = ${f.typ}(${nvm_unpack_expr(si, fi,
				'g_nvmres_${n}')})'
		}
		g << '\t}'
	}
	return g
}

// nvm_comm_locals: the comm thread's persist bookkeeping.
fn nvm_comm_locals(m Model, ioc_idx map[string]int) []string {
	if !nvm_on(m) {
		return []string{}
	}
	mut g := ['\t// [nvm]: last-persisted values + pacing (change+floor-gated puts).']
	g << '\t// Initialized from the staging cells, which boot() seeded with the'
	g << '\t// RESTORED values — the first pass sees no phantom change.'
	for sname in m.nvm_names {
		n := snake(sname)
		cell := ioc_idx[sname] or { 0 }
		g << '\tmut nvm_${n}_a := u32(0)'
		g << '\tmut nvm_${n}_b := u32(0)'
		g << '\tC.ioc_get(${cell}, &nvm_${n}_a, &nvm_${n}_b)'
		g << '\tmut nvm_${n}_t := u64(0)'
	}
	if m.nm.on {
		g << '\tmut nvm_prev_nm := g_nm.state()'
	}
	g << '\tmut nvm_pack := [8]u8{}'
	return g
}

// nvm_service: the comm-loop drain — floored puts for "now" signals, and the
// NM prepare-bus-sleep edge flushing EVERYTHING (both policies), marking the
// tail clean, and running the deferred erase inside the quiet window.
fn nvm_service(m Model, ioc_idx map[string]int) []string {
	if !nvm_on(m) {
		return []string{}
	}
	mut g := []string{}
	floor_us := u64(m.nvm.min_write_ms) * 1000
	for sname in m.nvm_names {
		si := m.sig_of[sname] or { continue }
		if si.persist != 'now' {
			continue
		}
		n := snake(sname)
		cell := ioc_idx[sname] or { 0 }
		id := m.nvm_ids[sname] or { 0 }
		g << '\t\t{ // persist "now": ${sname}'
		g << '\t\t\tmut a := u32(0)'
		g << '\t\t\tmut b := u32(0)'
		g << '\t\t\tC.ioc_get(${cell}, &a, &b)'
		g << '\t\t\tif (a != nvm_${n}_a || b != nvm_${n}_b) && t1 - nvm_${n}_t >= u64(${floor_us}) {'
		g << nvm_pack_lines(si, 4)
		g << '\t\t\t\tif g_nvm.put(${id}, &nvm_pack[0], ${si.packed_size()}) {'
		g << '\t\t\t\t\tnvm_${n}_a = a'
		g << '\t\t\t\t\tnvm_${n}_b = b'
		g << '\t\t\t\t\tnvm_${n}_t = t1'
		g << '\t\t\t\t}'
		g << '\t\t\t}'
		g << '\t\t}'
	}
	if m.nm.on {
		g << '\t\t{ // persist flush at the NM quiet point (docs/nvm.md choreography)'
		g << '\t\t\tnm_now := g_nm.state()'
		g << '\t\t\tif nm_now == .prepare_bus_sleep && nvm_prev_nm != .prepare_bus_sleep {'
		for sname in m.nvm_names {
			si := m.sig_of[sname] or { continue }
			n := snake(sname)
			cell := ioc_idx[sname] or { 0 }
			id := m.nvm_ids[sname] or { 0 }
			g << '\t\t\t\t{ // flush ${sname}'
			g << '\t\t\t\t\tmut a := u32(0)'
			g << '\t\t\t\t\tmut b := u32(0)'
			g << '\t\t\t\t\tC.ioc_get(${cell}, &a, &b)'
			g << '\t\t\t\t\tif a != nvm_${n}_a || b != nvm_${n}_b {'
			g << nvm_pack_lines(si, 6)
			g << '\t\t\t\t\t\tif g_nvm.put(${id}, &nvm_pack[0], ${si.packed_size()}) {'
			g << '\t\t\t\t\t\t\tnvm_${n}_a = a'
			g << '\t\t\t\t\t\t\tnvm_${n}_b = b'
			g << '\t\t\t\t\t\t}'
			g << '\t\t\t\t\t}'
			g << '\t\t\t\t}'
		}
		g << '\t\t\t\tg_nvm.mark_clean()'
		g << '\t\t\t\tg_nvm.erase_pending() // the deferred erase, in the quiet window'
		g << '\t\t\t}'
		g << '\t\t\tnvm_prev_nm = nm_now'
		g << '\t\t}'
	}
	return g
}

// nvm_pack_lines: pack the staged {a, b} pair into nvm_pack per field widths.
fn nvm_pack_lines(si SigInfo, indent int) []string {
	tabs := '\t'.repeat(indent)
	mut g := []string{}
	mut off := 0
	for fi, f in si.fields {
		src := if fi == 0 { 'a' } else { 'b' }
		w := field_width(f.typ)
		for b in 0 .. w {
			if b == 0 {
				g << '${tabs}nvm_pack[${off}] = u8(${src})'
			} else {
				g << '${tabs}nvm_pack[${off}] = u8(${src} >> ${8 * b})'
			}
			off++
		}
	}
	return g
}

fn nvm_manifest(m Model) []string {
	if !nvm_on(m) {
		return []string{}
	}
	mut g := ['# nvm signals: name,id,policy']
	for sname in m.nvm_names {
		si := m.sig_of[sname] or { continue }
		g << '${sname},0x${(m.nvm_ids[sname] or { 0 }).hex()},${si.persist}'
	}
	return g
}

// nvm_writer_thr: which thread owns each persistent signal's cell (the writer
// FB's thread) — restore targets that thread's state struct.
fn nvm_writer_thr(m Model, doc toml.Doc) map[string]string {
	mut out := map[string]string{}
	for fb in ecumodel.toml_arr(doc, 'fb') {
		fm := fb.as_map()
		fbname := (fm['name'] or { toml.Any('') }).string()
		thr := m.part.fb_thread[fbname] or { '' }
		for h in (fm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			for w in (h.as_map()['writes'] or { toml.Any([]toml.Any{}) }).array() {
				if (m.sig_of[w.string()] or { SigInfo{} }).persist != '' {
					out[w.string()] = thr
				}
			}
		}
	}
	return out
}
