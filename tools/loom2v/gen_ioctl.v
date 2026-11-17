module main

import math
import toml
import comm.uds

// Input/output control (0x2F, docs/diagnostics.md §3.1 "Input/output control"): a `control` on a
// live `signal` [[did]]. The server (comm/uds io_control.v) holds what a tester asked for; the
// value is substituted WHERE THE NODE ENCODES THE SIGNAL INTO ITS FRAME, on the thread that serves
// the server — the ThreadX comm thread (a local producer, gen.v; a satellite's lanes, gen_xcore.v)
// or the host bridge of the [isotp] bus (gen_com.v). No FB sees it and no FB declaration changes.
// This file holds the configuration's rules and the server's table; the emitters ask io_index.

// the control parameters a `control` may list, as the server's bit for each (00, return control to
// the ECU, is always served: bit 0)
const io_param_bits = {
	'reset_to_default':      u8(1) << uds.io_reset_to_default
	'freeze_current_state':  u8(1) << uds.io_freeze_current_state
	'short_term_adjustment': u8(1) << uds.io_short_term_adjustment
}

// parse_did_control reads a [[did]] `control = { parameters = [...], session = [...], security = N }`
// into the parameters served (bit 0 always), its session mask (absent = extended) and its level.
fn parse_did_control(cv toml.Any, id int) (u8, u8, u8) {
	h := '[[did]] 0x${id.hex()} control'
	if cv !is map[string]toml.Any {
		panic('loom2v: ${h} must be a table: control = { parameters = [...] }')
	}
	cm := cv.as_map()
	for key, _ in cm {
		if key !in ['parameters', 'session', 'security'] {
			panic('loom2v: ${h} has "${key}" — a control takes `parameters`, `session` and `security`')
		}
	}
	if 'parameters' !in cm {
		panic('loom2v: ${h} needs `parameters`: the control parameters served besides returnControlToECU (${io_param_bits.keys().join(' / ')})')
	}
	mut params := u8(1) // returnControlToECU
	for pv in (cm['parameters'] or { toml.Any([]toml.Any{}) }).array() {
		bit := io_param_bits[pv.string()] or {
			panic('loom2v: ${h} parameters names "${pv.string()}" — the parameters are ${io_param_bits.keys().join(' / ')} (returnControlToECU is always served)')
		}
		params |= bit
	}
	if params == 1 {
		panic('loom2v: ${h} parameters is empty — returnControlToECU alone takes no control; name the parameters served')
	}
	mut mask := uds.in_extended
	if 'session' in cm {
		mask = 0
		for sv in (cm['session'] or { toml.Any([]toml.Any{}) }).array() {
			bit := session_bit(sv.string()) or { panic('loom2v: ${h} session ${err}') }
			if bit == uds.in_default || bit == uds.in_programming {
				panic('loom2v: ${h} session names "${sv.string()}" — ISO 14229-1 runs 0x2F only outside the default session, and an application server never runs programming')
			}
			mask |= bit
		}
		if mask == 0 {
			panic('loom2v: ${h} session is empty — omit it for the extended session')
		}
	}
	sec := (cm['security'] or { toml.Any(0) }).int()
	if !schema_key('did_control', 'security').in_range(sec) {
		panic('loom2v: ${h} security ${sec} is not a 0x27 level the server serves (1..${schema_key('did_control',
			'security').max})')
	}
	// 0x27 unlocks in extended and every session change relocks (parse_did_access's rule)
	if sec != 0 && mask & uds.in_extended == 0 {
		panic('loom2v: ${h} needs security ${sec} but is not accepted in the extended session, the only one an application server unlocks in — it could never be taken')
	}
	return params, mask, u8(sec)
}

// io_controls: the controlled DIDs in declaration order — the server's control table, ios[k]
fn io_controls(m Model) []DidCfg {
	return m.dids.filter(it.control_params != 0)
}

// io_index: the control table index of the control of signal `sname`, or none
fn io_index(m Model, sname string) ?int {
	for k, d in io_controls(m) {
		if d.signal == sname {
			return k
		}
	}
	return none
}

// sess_and: two session masks together (0 = every session)
fn sess_and(a u8, b u8) u8 {
	return if a == 0 {
		b
	} else if b == 0 {
		a
	} else {
		a & b
	}
}

// io_gate: the gate the server enforces for DID d's control — its sessions within the 0x2F row's
// (the default table's or a configured one), and its level, else the row's (access_gate)
fn io_gate(m Model, d DidCfg) (u8, u8) {
	row, _ := svc_row(m, 0x2F)
	return access_gate(d.control_sessions, d.control_security, row)
}

// IoBounds: a controlled signal's range and default as values of its field
struct IoBounds {
	lo   i64
	hi   i64
	dflt i64
}

// field_range: the values a field type holds (a control's value is at most 32 bits)
fn field_range(typ string) ?(i64, i64) {
	return match typ {
		'bool' { i64(0), i64(1) }
		'u8' { i64(0), i64(255) }
		'i8' { i64(-128), i64(127) }
		'u16' { i64(0), i64(65535) }
		'i16' { i64(-32768), i64(32767) }
		'u32' { i64(0), i64(4294967295) }
		'i32' { i64(-2147483648), i64(2147483647) }
		else { none }
	}
}

// io_eps: the tolerance a value computed through f64 (factor * raw + offset, or its inverse) is
// compared with — that computation's rounding error and never a step of the value: relative 1e-12,
// and at most 0.25 absolute however large the value, so a bound is never moved past a whole value
fn io_eps(x f64) f64 {
	return math.min(1e-12 * math.max(1.0, math.abs(x)), 0.25)
}

// io_whole: whether x is a whole number, within the f64 conversion's error
fn io_whole(x f64) bool {
	return math.abs(x - math.round(x)) <= io_eps(x)
}

// io_bounds: signal si's range — its DBC raw range converted to physical values, ordered (a
// negative factor turns it over), as the whole values of its field inside it — and its default,
// the initial value (REQ-COM-011) converted the same way, which must be one of them. Two more rules
// make what the server says is published (comm/uds io_published) the value the frame carries,
// whoever chose it:
//   - every whole value in [lo, hi] is a raw step of the DBC's grid (the encoder rounds a value to
//     its nearest step, so one between two would go out as another);
//   - an end of the DBC range inside the field's values is itself a whole value (the encoder holds
//     an FB's value past it to that end, which the server's clamp to [lo, hi] then states exactly).
// So a value in [lo, hi] is never saturated nor rounded, and an FB's value is published clamped.
fn io_bounds(si SigInfo) !IoBounds {
	sg := si.dbc_lanes[0] or { return error('has no DBC signal') }
	if sg.name == '' {
		return error('has no DBC signal')
	}
	rr := sg.raw_range() or { return error('${err}') }
	tlo, thi := field_range(si.val_type) or { return error('is a ${si.val_type}') }
	pa := rr.lo * sg.factor + sg.offset
	pb := rr.hi * sg.factor + sg.offset
	pmin := math.min(pa, pb)
	pmax := math.max(pa, pb)
	flo := math.ceil(pmin - io_eps(pmin))
	fhi := math.floor(pmax + io_eps(pmax))
	lo := if flo > f64(tlo) { i64(flo) } else { tlo }
	hi := if fhi < f64(thi) { i64(fhi) } else { thi }
	if lo > hi {
		return error('has a DBC range [${sg.minimum}|${sg.maximum}] holding no value of its ${si.val_type} field')
	}
	for end in [pmin, pmax] {
		if end > f64(tlo) && end < f64(thi) && !io_whole(end) {
			return error('has a DBC range [${sg.minimum}|${sg.maximum}] ending at ${end}, which is not a value of its ${si.val_type} field — the encoder holds a function block\'s value past the end to it, so the value published could not be stated; a control needs whole ends')
		}
	}
	x0 := (f64(lo) - sg.offset) / sg.factor
	x1 := (f64(lo) + 1.0 - sg.offset) / sg.factor
	if !io_whole(x0) || (hi > lo && !io_whole(x1)) {
		off := if io_whole(x0) { lo + 1 } else { lo }
		return error('has factor ${sg.factor} and offset ${sg.offset}: ${off}, a value of its field in its range, falls between two raw steps and would be sent rounded to another — a control needs a DBC grid holding every whole value (1 / factor and offset / factor whole)')
	}
	raw := sg.init_raw() or { return error('${err}') }
	n := sg.length
	mask := if n >= 64 { ~u64(0) } else { (u64(1) << n) - 1 }
	steps := if sg.is_signed && n < 64 && raw & (u64(1) << (n - 1)) != 0 {
		f64(i64(raw | ~mask))
	} else if sg.is_signed {
		f64(i64(raw))
	} else {
		f64(raw)
	}
	d := steps * sg.factor + sg.offset
	r := math.round(d)
	if !io_whole(d) || r < f64(lo) || r > f64(hi) {
		return error('has the initial value ${d}, which is not a value of its ${si.val_type} field in ${lo}..${hi} — resetToDefault, a freeze before the first publish and every read until then publish it')
	}
	return IoBounds{
		lo:   lo
		hi:   hi
		dflt: i64(r)
	}
}

// io_signal_refusal: why signal si cannot be controlled on this node ('' = it can) — it must be a
// value an FB writes and the node sends on a CAN bus, encoded by the thread serving the server. A
// live DID of an I/O point's or an Ethernet signal is refused before this by ecumodel's reader rule
// (its channel has one reader, which is not the diagnostic refresh); this function refuses them too,
// so a control never depends on that rule staying as it is (io_control_test asks it directly).
fn io_signal_refusal(m Model, si SigInfo) string {
	if si.rx {
		return 'is received by the node — a control overrides what the node publishes, never what it reads'
	}
	if si.io_in {
		return 'comes in from an I/O point — it is an input'
	}
	if si.io_out {
		return 'is written to an I/O point, which the io thread applies, not the thread serving the diagnostic server'
	}
	if !si.external {
		return if si.remote {
			'is a satellite FB\'s value no frame of this node publishes'
		} else {
			'stays inside the node (FB to FB) — no frame publishes it'
		}
	}
	if m.eth != '' && si.bus == m.eth {
		return 'is sent on the Ethernet bus "${si.bus}" by the eth thread, not the thread serving the diagnostic server'
	}
	if !m.target.threadx && si.bus != m.isotp_conns[0].bus {
		return 'is sent on bus "${si.bus}", whose bridge is not the one serving the diagnostic server (the [isotp] bus "${m.isotp_conns[0].bus}")'
	}
	return ''
}

// validate_io_controls refuses a control the server cannot apply (REQ-DIAG-104), naming why.
fn validate_io_controls(m Model) {
	ctl := io_controls(m)
	if ctl.len == 0 {
		return
	}
	if m.isotp_conns.len == 0 {
		panic('loom2v: [[did]] 0x${ctl[0].id.hex()} control: a control is served by the diagnostic server (0x2F) — declare its [isotp] connection')
	}
	if m.target.on && !m.target.threadx {
		panic('loom2v: [[did]] 0x${ctl[0].id.hex()} control: a bare-metal target serves no diagnostic server — a control is the host bridge\'s or a ThreadX comm thread\'s')
	}
	if ctl.len > uds.max_ios {
		panic('loom2v: ${ctl.len} [[did]]s declare a `control` — a diagnostic server holds at most ${uds.max_ios} (comm/uds max_ios)')
	}
	mut seen := map[string]int{}
	r22, _ := svc_row(m, 0x22)
	for d in ctl {
		h := '[[did]] 0x${d.id.hex()} control'
		si := m.sig_of[d.signal] or { panic('loom2v: ${h}: "${d.signal}" is no signal of this node') }
		why := io_signal_refusal(m, si)
		if why != '' {
			panic('loom2v: ${h}: "${d.signal}" ${why} — 0x2F overrides a value where the node encodes it into its frame, on the thread that serves the diagnostic server (docs/diagnostics.md §3.1)')
		}
		if si.fields.len > 1 {
			panic('loom2v: ${h}: "${d.signal}" has ${si.fields.len} fields — a control of several fields needs a controlEnableMask, which is not supported; control a single-field signal')
		}
		w := did_value_width(si.val_type) or { 0 }
		if w == 0 || w > 4 {
			panic('loom2v: ${h}: "${d.signal}" is a ${si.val_type} — a control value is an integer or a bool of at most 32 bits')
		}
		if prev := seen[d.signal] {
			panic('loom2v: ${h}: [[did]] 0x${prev.hex()} already controls "${d.signal}" — one signal, one control')
		}
		seen[d.signal] = d.id
		sg := si.dbc_lanes[0] or { panic('loom2v: ${h}: "${d.signal}" has no DBC signal') }
		rr := sg.raw_range() or { panic('loom2v: ${h}: "${d.signal}": ${err}') }
		if rr.named.len > 0 {
			panic('loom2v: ${h}: "${d.signal}" names a value outside its range in the DBC (VAL_ ${rr.named[0].raw} "${rr.named[0].label}"), which is sent as itself — a value under control is held to [${sg.minimum}|${sg.maximum}], so such a signal is not supported')
		}
		io_bounds(si) or { panic('loom2v: ${h}: "${d.signal}" ${err}') }
		// the 0x6F answer carries the value, and 00 is always accepted: a control gate weaker than
		// the read's would read through a 0x22 refusal
		rs, rl := access_gate(d.read_sessions, d.read_security, r22)
		cs, cl := io_gate(m, d)
		if rs != 0 && cs & ~rs != 0 {
			panic('loom2v: ${h} is accepted in a session the DID\'s read refuses — its answer carries the value 0x22 would not show; narrow `session`')
		}
		if rl != 0 && cl != rl {
			needs := if cl == 0 { 'needs no security level' } else { 'needs security ${cl}' }
			panic('loom2v: ${h} ${needs}, but the DID\'s read needs ${rl} — its answer carries the value 0x22 would not show; give it security = ${rl}')
		}
	}
}

// io_init_lines: the server's control table, for both owners (conn_init_lines)
fn io_init_lines(m Model, srv string) []string {
	ctl := io_controls(m)
	mut g := []string{}
	for k, d in ctl {
		si := m.sig_of[d.signal] or { panic('loom2v: [[did]] 0x${d.id.hex()}: no signal "${d.signal}"') }
		b := io_bounds(si) or { panic('loom2v: [[did]] 0x${d.id.hex()} control: ${err}') }
		sessions, level := io_gate(m, d)
		if sessions == 0 {
			// validate_uds refused a control sharing no session with its row: 0 would read "every"
			panic('loom2v: internal: [[did]] 0x${d.id.hex()} control has no session')
		}
		g << '\t${srv}.ios[${k}] = uds.IoControl{ // 0x2F on ${d.signal}'
		g << '\t\tdid:      u16(0x${d.id.hex()})'
		g << '\t\twidth:    ${did_value_width(si.val_type) or { 0 }}'
		if si.val_type in ['i8', 'i16', 'i32'] {
			g << '\t\tsigned:   true'
		}
		g << '\t\tlo:       i64(${b.lo})'
		g << '\t\thi:       i64(${b.hi})'
		g << '\t\tdflt:     i64(${b.dflt})'
		g << '\t\tparams:   u8(0x${d.control_params.hex()})'
		g << '\t\tsessions: u8(0x${sessions.hex()})'
		if level != 0 {
			g << '\t\tsecurity: u8(${level})'
		}
		g << '\t}'
	}
	if ctl.len > 0 {
		g << '\t${srv}.nio = ${ctl.len}'
	}
	return g
}

// as_i64: a value of field type `typ` as the i64 the server holds — from a u32 IOC cell or lane
// (`u32(field)`, a signed field read back through its sign, a bool as 0 / 1) or from a typed field
fn as_i64(typ string, expr string, from_cell bool) string {
	if typ == 'bool' {
		return if from_cell {
			'if ${expr} != 0 { i64(1) } else { i64(0) }'
		} else {
			'if ${expr} { i64(1) } else { i64(0) }'
		}
	}
	if from_cell && typ in ['i8', 'i16', 'i32'] {
		return 'i64(i32(${expr}))'
	}
	return 'i64(${expr})'
}

// io_field_of: the server's i64 `expr` back as field type `typ` — a host field (a bool from 0 / 1)
fn io_field_of(typ string, expr string) string {
	return if typ == 'bool' { '${expr} != 0' } else { '${typ}(${expr})' }
}

// io_target_fns: the target's conditions seam as the server calls it (boards/common/diag_io_ok.h
// diag_io_ok, weak: accepting unless the node's glue states conditions) — REQ-DIAG-106
fn io_target_fns(m Model) []string {
	if m.isotp_conns.len == 0 || io_controls(m).len == 0 {
		return []string{}
	}
	return ['', 'fn C.diag_io_ok(u16, u8) int', '', 'fn diag_io_ok_v(did u16, parameter u8) bool {',
		'\treturn C.diag_io_ok(did, parameter) != 0', '}']
}
