// loom2v's owner -> satellite signal emission — the "down" half of the cross-core transport.
//
// A signal produced on the OWNER image (by an owner FB, or decoded from a bus by the comm thread)
// that an FB in a satellite image READS gets a down channel: an xioc_n channel in the board's
// owner-written window (xcore.h XCORE_OW_*), written by the one owner context that produces the
// signal and read by the satellite FB wrapper. Readers are derived from the FBs' `reads`, never
// from a signal's single `to`, so an owner FB and a satellite FB may read one signal (the writer
// feeds both). Nothing is configured: the channel exists because of where the FBs are placed
// (docs/multi-image.md, REQ-INV-006).
//
// The seams are shared C, linked by symbol (glue_build_lines): boards/<board>/xcore_owner.c
// (begin / per-channel init / commit at boot, the writer) and boards/<board>/xcore_sat.c (the
// gated reader, whose state the reading thread holds).
module main

import toml
import tools.ecumodel

// xlane_types: the field types a cross-core lane carries (one u32 lane each; the 64-bit ones two,
// low word first). A channel is copied whole under its sequence stamp, so a 64-bit field never
// tears across its two lanes.
const xlane_types = ['bool', 'u8', 'u16', 'u32', 'i8', 'i16', 'i32', 'f32', 'u64', 'i64', 'f64']

// rx_status_names: RxStatus in declaration order (its value is the index) — the ONE list the enum
// (emit_signals) and its cross-core lane decode (xlane_helpers) are both written from
const rx_status_names = ['never_received', 'ok', 'timeout', 'integrity']
const rx_status_notes = ['no good frame yet', 'the value came from a good frame',
	'the reception deadline passed (silence is the newest fact)',
	'the newest frame failed its E2E CRC or its SecOC check']

// xlane_max: lanes per channel — one 64 B PDU (xioc.h XIOC_MAX_WORDS).
const xlane_max = 16

// field_lanes: the u32 lanes one field takes.
fn field_lanes(typ string) int {
	return if typ in ['u64', 'i64', 'f64'] { 2 } else { 1 }
}

// sig_lanes: the u32 lanes a signal's whole struct takes.
fn sig_lanes(si SigInfo) int {
	mut n := 0
	for f in si.fields {
		n += field_lanes(f.typ)
	}
	return n
}

// xioc_n_bytes: one xioc_n channel's footprint (xioc.h XIOC_N_BYTES): a 32 B header plus four
// slots of one seq word and the lanes, rounded up to the 32 B line.
fn xioc_n_bytes(lanes int) int {
	return (32 + 4 * 4 * (1 + lanes) + 31) & ~31
}

// lane_type_issue: why a field cannot ride a lane ('' = it can). `status_ok` admits a received
// signal's RxStatus, which a down channel carries as one lane.
fn lane_type_issue(sname string, f SigField, status_ok bool) string {
	if f.typ in xlane_types || (status_ok && f.typ == 'RxStatus') {
		return ''
	}
	return 'cross-core signal "${sname}" field "${f.name}" is ${f.typ} — a lane carries ' +
		'${xlane_types.join(' / ')}'
}

// lane_pack_lines: `arr`[..] = the fields of `src` (an expression of the signal's struct), in
// field order — the one lane encode both directions use.
fn lane_pack_lines(si SigInfo, src string, arr string, ind string) []string {
	mut g := []string{}
	mut k := 0
	for f in si.fields {
		x := '${src}.${snake(f.name)}'
		match f.typ {
			'u32' {
				g << '${ind}${arr}[${k}] = ${x}'
			}
			'bool' {
				g << '${ind}${arr}[${k}] = if ${x} { u32(1) } else { u32(0) }'
			}
			'f32' {
				g << '${ind}${arr}[${k}] = xlane_f32_bits(${x})'
			}
			'u64', 'i64' {
				g << '${ind}${arr}[${k}] = u32(u64(${x}))'
				g << '${ind}${arr}[${k + 1}] = u32(u64(${x}) >> 32)'
			}
			'f64' {
				g << '${ind}${arr}[${k}] = u32(xlane_f64_bits(${x}))'
				g << '${ind}${arr}[${k + 1}] = u32(xlane_f64_bits(${x}) >> 32)'
			}
			'RxStatus' {
				g << '${ind}${arr}[${k}] = u32(u8(${x}))'
			}
			else {
				g << '${ind}${arr}[${k}] = u32(${x})'
			}
		}
		k += field_lanes(f.typ)
	}
	return g
}

// lane_value: the field value lane `k` (and k+1) of `arr` holds — the inverse of lane_pack_lines.
fn lane_value(typ string, arr string, k int) string {
	l := '${arr}[${k}]'
	return match typ {
		'u32' { l }
		'bool' { '${l} != 0' }
		'f32' { 'xlane_f32_from(${l})' }
		'u64' { '(u64(${arr}[${k + 1}]) << 32) | u64(${l})' }
		'i64' { 'i64((u64(${arr}[${k + 1}]) << 32) | u64(${l}))' }
		'f64' { 'xlane_f64_from((u64(${arr}[${k + 1}]) << 32) | u64(${l}))' }
		'RxStatus' { 'xlane_rx_status(${l})' }
		else { '${typ}(${l})' }
	}
}

// lane_unpack_lines: `dst`'s fields from `arr` starting at lane `base`. A lean down signal (one
// lane, `lean`) sets only the value field, as the owner's lean read does.
fn lane_unpack_lines(si SigInfo, arr string, base int, dst string, lean bool, ind string) []string {
	if lean {
		return ['${ind}${dst}.${snake(si.val_field)} = ${lane_value(si.val_type, arr, base)}']
	}
	mut g := []string{}
	mut k := base
	for f in si.fields {
		g << '${ind}${dst}.${snake(f.name)} = ${lane_value(f.typ, arr, k)}'
		k += field_lanes(f.typ)
	}
	return g
}

// xlane_helpers: the bit casts f32/f64 lanes need, emitted once into an image that carries one.
fn xlane_helpers(sigs []SigInfo) []string {
	mut f32s := false
	mut f64s := false
	mut status := false
	for si in sigs {
		for f in si.fields {
			f32s = f32s || f.typ == 'f32'
			f64s = f64s || f.typ == 'f64'
			status = status || f.typ == 'RxStatus'
		}
	}
	mut g := []string{}
	if status {
		g << ''
		g << '// a received signal\'s RxStatus crosses cores as one lane (its enum value)'
		g << 'fn xlane_rx_status(l u32) sig.RxStatus {'
		g << '\treturn match l {'
		for i, name in rx_status_names {
			if i > 0 {
				g << '\t\t${i} { .${name} }'
			}
		}
		g << '\t\telse { .${rx_status_names[0]} }'
		g << '\t}'
		g << '}'
	}
	if f32s {
		g << ''
		g << '// an f32 field crosses cores as its bits (one lane)'
		g << '@[inline]'
		g << 'fn xlane_f32_bits(x f32) u32 {'
		g << '\treturn unsafe { *(&u32(&x)) }'
		g << '}'
		g << ''
		g << '@[inline]'
		g << 'fn xlane_f32_from(l u32) f32 {'
		g << '\treturn unsafe { *(&f32(&l)) }'
		g << '}'
	}
	if f64s {
		g << ''
		g << '// an f64 field crosses cores as its bits (two lanes, low word first)'
		g << '@[inline]'
		g << 'fn xlane_f64_bits(x f64) u64 {'
		g << '\treturn unsafe { *(&u64(&x)) }'
		g << '}'
		g << ''
		g << '@[inline]'
		g << 'fn xlane_f64_from(l u64) f64 {'
		g << '\treturn unsafe { *(&f64(&l)) }'
		g << '}'
	}
	return g
}

// xcore_sigs: every signal that crosses cores (either direction), for xlane_helpers.
fn xcore_sigs(m Model) []SigInfo {
	mut out := []SigInfo{}
	for n in m.xcore_names {
		out << m.sig_of[n] or { continue }
	}
	for n in m.xdown_names {
		out << m.sig_of[n] or { continue }
	}
	return out
}

// FbRW is one FB as the derivation sees it: where it runs and what its handlers read and write.
struct FbRW {
	name   string
	part   string
	thread string
	reads  []string
	writes []string
}

// fb_rw_list: every [[fb]] with its partition, thread, reads and writes (ecumodel.fb_places, the
// one walk of the FBs placement reads)
fn fb_rw_list(doc toml.Doc) []FbRW {
	return ecumodel.fb_places(doc).map(FbRW{
		name:   it.name
		part:   it.part
		thread: it.thread
		reads:  it.reads
		writes: it.writes
	})
}

// ep_part: the partition a signal endpoint names — a partition itself, or the partition of the
// thread it names ('' for a bus, `io`, or anything else).
fn ep_part(p PartMap, ep string) string {
	if ep in p.core_of {
		return ep
	}
	return p.thread_part[ep] or { '' }
}

// fb_reads_owner: how many OWNER FBs (not in a satellite partition) read each signal — what the
// owner's IOC cells, byte-IOC cells and lean-receive publishes are allocated for.
fn fb_reads_owner(fbs []FbRW, p PartMap) map[string]int {
	mut n := map[string]int{}
	for fb in fbs {
		if p.external[fb.part] or { false } {
			continue
		}
		for r in fb.reads {
			n[r]++
		}
	}
	return n
}

// XDown is the derived owner -> satellite map: the down channels in declaration order, each one's
// offset in the owner window, its lane count, and whether it is a lean received signal (one lane,
// the value field, published by the comm thread's lean decode).
struct XDown {
mut:
	names []string
	off   map[string]int
	lanes map[string]int
	lean  map[string]bool
	param map[string]bool // a [[param]]'s channel: its fields as param_pub publishes them
	// a persisted signal a satellite FB writes: the journal's restore, read once by the writer's
	// thread before its first dispatch (REQ-PLACE-006) — never an FB input
	persist map[string]bool
	total   int
}

// xdown_derive decides which signals need a down channel and lays them out, or says why a
// satellite reader cannot be served. `params` are the node's [[param]]s. `checked` is the set of received DBC messages the comm
// thread runs through the COM receive rule (rx_checked_msgs); `eth` the eth bus name ('' = none).
fn xdown_derive(sig_names []string, sig_of map[string]SigInfo, params []ParamCfg, p PartMap, fbs []FbRW, checked []string, eth string) !XDown {
	mut d := XDown{}
	for sname in sig_names {
		si := sig_of[sname] or { continue }
		sat := fbs.filter(sname in it.reads && (p.external[it.part] or { false }))
		if sat.len == 0 {
			continue
		}
		fp := ep_part(p, si.from)
		if fp != '' && (p.external[fp] or { false }) {
			continue // produced on a satellite: the up direction (or local to that image)
		}
		for r in sat {
			if (p.image[r.part] or { '' }) == '' {
				return error('signal "${sname}" is read by fb "${r.name}" in partition "${r.part}", ' +
					'a hand-written satellite (external = true) — owner->satellite channels are ' +
					'generated for image = partitions only (docs/multi-image.md)')
			}
		}
		if si.io_in || si.from == 'io' {
			return error('signal "${sname}" comes from an io point, which the io thread publishes on ' +
				'the owner image; a satellite fb ("${sat[0].name}") reading it is not generated ' +
				'(docs/io.md) — read it on the owner image')
		}
		if si.rx && eth != '' && si.bus == eth {
			return error('signal "${sname}" is received on the eth bus, which the eth thread owns; a ' +
				'satellite fb ("${sat[0].name}") reading it is not generated (docs/multi-image.md) — ' +
				'read it on the owner image')
		}
		if si.external && !si.rx {
			return error('signal "${sname}" is sent on bus "${si.bus}" and read by satellite fb ' +
				'"${sat[0].name}" — a signal the comm thread transmits is not also an fb input, on ' +
				'one core or two; write a second signal for the reader')
		}
		lean := si.rx && si.dbc_msg !in checked
		mut lanes := 1
		if !lean {
			for f in si.fields {
				issue := lane_type_issue(sname, f, si.rx)
				if issue != '' {
					return error(issue)
				}
			}
			lanes = sig_lanes(si)
		}
		if lanes < 1 || lanes > xlane_max {
			return error('cross-core signal "${sname}" takes ${lanes} lanes — a channel carries ' +
				'1..${xlane_max} (one PDU, 64 B); a bigger payload is bulk, not a signal ' +
				'(docs/bulk-transport.md)')
		}
		if !si.rx {
			mut writers := []string{}
			for fb in fbs {
				if sname in fb.writes && fb.thread !in writers {
					writers << fb.thread
				}
			}
			if writers.len > 1 {
				writers.sort()
				return error('cross-core signal "${sname}" is written from ${writers.len} threads ' +
					'(${writers.join(', ')}) — a channel has exactly ONE producer context (SPSC); ' +
					'keep its writers on one thread or split the signal')
			}
		}
		d.names << sname
		d.off[sname] = d.total
		d.lanes[sname] = lanes
		d.lean[sname] = lean
		d.total += xioc_n_bytes(lanes)
	}
	// a parameter a satellite FB reads: one lane per field, as param_pub publishes it (REQ-PLACE-007)
	for pc in params {
		sat := fbs.filter(pc.name in it.reads && (p.external[it.part] or { false }))
		if sat.len == 0 {
			continue
		}
		for r in sat {
			if (p.image[r.part] or { '' }) == '' {
				return error('parameter "${pc.name}" is read by fb "${r.name}" in partition "${r.part}", ' +
					'a hand-written satellite (external = true) — owner->satellite channels are ' +
					'generated for image = partitions only (docs/multi-image.md)')
			}
		}
		d.names << pc.name
		d.off[pc.name] = d.total
		d.lanes[pc.name] = pc.fields.len
		d.param[pc.name] = true
		d.total += xioc_n_bytes(pc.fields.len)
	}
	// a persisted signal a satellite FB writes: the restored value, one lane per field, written by
	// the owner's boot before the satellite is released (REQ-PLACE-006)
	for sname in sig_names {
		si := sig_of[sname] or { continue }
		if si.persist == '' {
			continue
		}
		wp := ep_part(p, si.from)
		if wp == '' || (p.image[wp] or { '' }) == '' {
			continue // on the owner, or a hand-written satellite (derive_nvm refuses it)
		}
		d.names << sname
		d.off[sname] = d.total
		d.lanes[sname] = sig_lanes(si)
		d.persist[sname] = true
		d.total += xioc_n_bytes(sig_lanes(si))
	}
	return d
}

// xdown_fb_input: whether an FB on a satellite reads `name` from a down channel each dispatch —
// every down channel but a persisted signal's restore, which seeds the writer's cell once.
fn xdown_fb_input(m Model, name string) bool {
	return name in m.xdown_off && !(m.xdown_persist[name] or { false })
}

// xdown_on: any owner -> satellite channel in the model.
fn xdown_on(m Model) bool {
	return m.xdown_names.len > 0
}

// xdown_gen_h: the down channels' part of gen/xcore_gen.h — offsets in the owner window, lane
// counts and the window budget.
fn xdown_gen_h(m Model) []string {
	if !xdown_on(m) {
		return []string{}
	}
	mut g := ['/* owner -> satellite (xioc_n) channels: byte offsets inside the owner-written window',
		' * (xcore.h XCORE_OW_CH_ADDR); words = u32 lanes. The owner inits + writes, the satellite reads. */']
	for sname in m.xdown_names {
		u := snake(sname).to_upper()
		g << '#define XCORE_OW_${u}_OFF ${m.xdown_off[sname] or { 0 }}u'
		g << '#define XCORE_OW_${u}_WORDS ${m.xdown_lanes[sname] or { 0 }}u'
	}
	g << '#define XCORE_OW_TOTAL ${m.xdown_total}u'
	g << '#if defined(XCORE_OW_MAX) && (XCORE_OW_TOTAL > XCORE_OW_MAX)'
	g << '#error "owner->satellite channels overflow the owner window — grow XCORE_OW_MAX (xcore.h) or shed signals"'
	g << '#endif'
	return g
}

// xdown_layout_desc: the down channels' part of the layout-id string. `o:` marks the direction.
fn xdown_layout_desc(m Model) string {
	mut desc := ''
	for sname in m.xdown_names {
		mut fs := ''
		if pc := param_of(m, sname) {
			for f in pc.fields {
				fs += '${f.name}=${f.typ},'
			}
			desc += 'o:${sname}:ow+${m.xdown_off[sname] or { 0 }}:${m.xdown_lanes[sname] or { 0 }}[p:${fs}]|'
			continue
		}
		si := m.sig_of[sname] or { continue }
		if m.xdown_persist[sname] or { false } {
			fs = 'n:' // the journal's restore, not an FB input
		}
		if m.xdown_lean[sname] or { false } {
			fs = '${si.val_field}=${si.val_type},'
		} else {
			for f in si.fields {
				fs += '${f.name}=${f.typ},'
			}
		}
		desc += 'o:${sname}:ow+${m.xdown_off[sname] or { 0 }}:${m.xdown_lanes[sname] or { 0 }}[${fs}]|'
	}
	return desc
}

// xdown_owner_decls: the owner's seams (boards/<board>/xcore_owner.c).
// Every satellite owner declares begin/commit, channels or not: its boot retracts and re-acks the
// window, so a satellite built for down channels this owner no longer has reads never-fresh.
fn xdown_owner_decls(m Model) []string {
	if !has_satellite(m) {
		return []string{}
	}
	mut g := [
		'fn C.xcore_owner_begin() // owner->satellite window: retract the ack, new boot nonce',
		'fn C.xcore_owner_commit() // publish the ack: the satellite may read the down channels',
	]
	if xdown_on(m) {
		g << 'fn C.xcore_ow_init(u32, u32) // one down channel (window offset, lanes), seeded per boot'
		g << 'fn C.xcore_opub_n(u32, &u32) // down channel writer (window offset, &lanes[0])'
	}
	return g
}

// xdown_boot_lines: the owner's window bring-up, emitted in boot() BEFORE the satellite is
// released, so the satellite never sees a channel of this boot before it is initialised — on every
// satellite owner, so the retained ack of an earlier build is always retracted.
fn xdown_boot_lines(m Model) []string {
	if !has_satellite(m) {
		return []string{}
	}
	mut g := ['\tC.xcore_owner_begin() // owner->satellite window: retract, then init, then publish']
	for sname in m.xdown_names {
		g << '\tC.xcore_ow_init(u32(${m.xdown_off[sname] or { 0 }}), u32(${m.xdown_lanes[sname] or { 0 }})) // ${sname}'
	}
	g << '\tC.xcore_owner_commit()'
	return g
}

// xdown_pub_fns: one writer per non-lean down channel — the signal's struct packed into lanes and
// published. Called by the owner FB that writes it, or by the comm thread's checked receive.
fn xdown_pub_fns(m Model) []string {
	mut g := []string{}
	for sname in m.xdown_names {
		if (m.xdown_lean[sname] or { false }) || (m.xdown_param[sname] or { false })
			|| (m.xdown_persist[sname] or { false }) {
			continue // the comm thread's lean decode, param_pub, or the journal's restore writes these
		}
		si := m.sig_of[sname] or { continue }
		n := snake(sname)
		g << ''
		g << '// ${sname} -> the satellite (owner->satellite channel, xcore_gen.h XCORE_OW_${n.to_upper()}_OFF)'
		g << 'fn xdown_pub_${n}(v sig.${sname}) {'
		g << '\tmut l := [${m.xdown_lanes[sname] or { 0 }}]u32{}'
		g << lane_pack_lines(si, 'v', 'l', '\t')
		g << '\tC.xcore_opub_n(u32(${m.xdown_off[sname] or { 0 }}), &l[0])'
		g << '}'
	}
	return g
}

// xdown_lean_pub: the comm thread's lean-decode publish of `dbc_id` to the satellite, '' when no
// lean down channel is carried by that frame.
fn xdown_lean_pub(m Model, dbc_id int) string {
	for sname in m.xdown_names {
		si := m.sig_of[sname] or { continue }
		if (m.xdown_lean[sname] or { false }) && si.dbc_id == dbc_id {
			return 'C.xcore_opub_n(u32(${m.xdown_off[sname] or { 0 }}), &g_rx_last) // ${sname} -> the satellite'
		}
	}
	return ''
}

// xdown_reader_decls: the satellite's seam (boards/<board>/xcore_sat.c), when `part` reads one.
fn xdown_reader_decls(m Model, part string) []string {
	if !xdown_reads(m, part) {
		return []string{}
	}
	return ['fn C.xcore_down_read(u32, u32, &u32) int // owner->satellite reader: (window offset, lanes, &state[0]); 1 = state holds a value of this owner boot']
}

// xdown_reads: whether an FB of `part` reads a down channel.
fn xdown_reads(m Model, part string) bool {
	for c in m.part.by_part[part] or { []toml.Any{} } {
		name := (c.as_map()['name'] or { toml.Any('') }).string()
		if (m.fb_reads_by[name] or { []string{} }).any(it in m.xdown_off) {
			return true
		}
	}
	return false
}

// xreader_state_fields: the cross-core reader state a thread holds, one array per signal it reads
// — the satellite's down channels ([nonce, seq, lanes...]) or, on the owner, wide up channels
// ([seq, lanes...]). In the thread's own state, so any number of reader threads is safe: the
// xioc_n reader writes nothing shared.
fn xreader_state_fields(m Model, reads []string, image_part string) []string {
	mut g := []string{}
	for rn in reads {
		if image_part != '' && xdown_fb_input(m, rn) {
			g << '\txr_${snake(rn)} [${(m.xdown_lanes[rn] or { 0 }) + 2}]u32 // ${rn}: owner nonce, seq, lanes (xcore_down_read)'
		} else if image_part == '' && m.target.threadx && rn in m.xcore_xw_off {
			si := m.sig_of[rn] or { continue }
			g << '\txr_${snake(rn)} [${sig_lanes(si) + 1}]u32 // ${rn}: seq, lanes (xcore_poll_n)'
		}
	}
	return g
}

// xdown_read_lines: a satellite FB wrapper's read of down channel `rn` into `inp`.
fn xdown_read_lines(m Model, rn string) []string {
	n := snake(rn)
	lanes := m.xdown_lanes[rn] or { 0 }
	mut g := ['\t// ${rn} from the owner image: the port default (a parameter\'s declared one) until the owner publishes in this boot']
	g << '\tif C.xcore_down_read(u32(${m.xdown_off[rn] or { 0 }}), u32(${lanes}), &st.xr_${n}[0]) != 0 {'
	if pc := param_of(m, rn) {
		// param_pub's lanes, decoded as the owner's cell is
		mut lanes_of := []string{}
		for i in 0 .. pc.fields.len {
			lanes_of << 'st.xr_${n}[${2 + i}]'
		}
		g << param_field_lines(pc, lanes_of, '\t\t')
		// no value of this owner boot (a build the gate refuses): what an uncoded vehicle runs
		g << '\t} else {'
		for f in pc.fields {
			g << if f.typ == 'bool' {
				'\t\tinp.${n}.${snake(f.name)} = ${f.def != 0}'
			} else {
				'\t\tinp.${n}.${snake(f.name)} = ${f.typ}(${f.def})'
			}
		}
	} else {
		si := m.sig_of[rn] or { SigInfo{} }
		g << lane_unpack_lines(si, 'st.xr_${n}', 2, 'inp.${n}', m.xdown_lean[rn] or { false }, '\t\t')
	}
	g << '\t}'
	return g
}

// xup_wide_read_lines: an owner FB wrapper's read of WIDE up channel `rn` (satellite -> owner),
// gated on the layout handshake like the pair read; the port default until the first value.
fn xup_wide_read_lines(m Model, rn string) []string {
	si := m.sig_of[rn] or { SigInfo{} }
	n := snake(rn)
	mut g := ['\tif C.xcore_layout_ok() != 0 { // trust cross-core channels only once the satellite acks a matched build']
	g << '\t\tC.xcore_poll_n(u32(${m.xcore_xw_off[rn] or { 0 }}), ${sig_lanes(si)}, &st.xr_${n}[0], &st.xr_${n}[1])'
	g << '\t\tif st.xr_${n}[0] != 0 {'
	g << lane_unpack_lines(si, 'st.xr_${n}', 1, 'inp.${n}', false, '\t\t\t')
	g << '\t\t}'
	g << '\t}'
	return g
}

// up_pub_lines: a satellite FB wrapper's publish of up signal `wn` (satellite -> owner) — the wide
// channel's lanes, or the {a, b} pair slot. Field order = lane order = wire order.
fn up_pub_lines(m Model, si SigInfo, wn string) []string {
	n := snake(wn)
	if xoff := m.xcore_xw_off[wn] {
		mut g := ['\tmut xw_${n} := [${sig_lanes(si)}]u32{}']
		g << lane_pack_lines(si, 'outp.${n}', 'xw_${n}', '\t')
		g << '\tC.xcore_pub_n(u32(${xoff}), &xw_${n}[0])'
		return g
	}
	b_expr := if si.fields.len > 1 { 'u32(outp.${n}.${snake(si.fields[1].name)})' } else { 'u32(0)' }
	return ['\tC.xcore_pub(${m.xcore_idx[wn] or { 0 }}, u32(outp.${n}.${snake(si.fields[0].name)}), ${b_expr})']
}
