module ecumodel

import toml
import tools.candb

// e2e.v — a CAN frame's effective E2E layout: its [[frame]].e2e, else what the DBC declares
// through blobly_net#271's attributes. ONE resolution, so every tool that asks about a CAN frame
// agrees. (SOME/IP frames have no DBC: their trailer layout is derived, see validate_someip.)

// FrameE2e is where comm/e2e stamps a frame: the profile, the Data ID, the CRC's (first) byte,
// and the counter's byte — Profile 1's counter is that byte's low nibble, Profile 5's the whole
// byte after its 2-byte CRC — and, for a receiver, E2E's own sender-loss timeout (0 = none).
pub struct FrameE2e {
pub:
	profile     string = candb.p01 // candb.p01 or candb.p05
	data_id     int
	crc_pos     int
	counter_pos int
	timeout_ms  i64
	// a DBC E2ETimeout that is not a number of ms, and nothing replaced it: only a receiver
	// needs a timeout, so it is reported where one is required, not here
	bad_timeout string
}

// dbc_e2e is the layout the DBC declares for `m`, refused where comm/e2e cannot stamp it:
// a profile other than autosar_p01 and autosar_p05 (the two it implements), a missing or
// out-of-range Data ID, or signals that are not the profile's fields — for P01 an 8-bit
// byte-aligned CRC and a 4-bit counter in a byte's low nibble, for P05 a 16-bit little-endian
// byte-aligned CRC and an 8-bit byte-aligned counter in the byte after it (blobly_net's
// p05_problem, the same rule). The bool is false when the DBC declares nothing.
pub fn dbc_e2e(m candb.Message) !(FrameE2e, bool) {
	d := m.e2e
	if !d.declared() {
		return FrameE2e{}, false
	}
	what := 'frame "${m.name}": the DBC\'s E2E declaration'
	if d.profile !in candb.profiles {
		return error('${what} names profile "${d.profile}" — only P01 and P05 (AUTOSAR E2E Profiles 1 and 5) are implemented')
	}
	if d.bad_data_id != '' {
		return error('${what} has E2EDataId "${d.bad_data_id}", which is not a Data ID')
	}
	if !d.has_data_id || d.data_id > 0xFFFF {
		return error('${what} needs an E2EDataId in 0..0xFFFF')
	}
	p05 := d.profile == candb.p05
	crc := if p05 {
		e2e_crc16_of(m, d.crc) or { return error('${what}: E2ECrcSignal ${err.msg()}') }
	} else {
		e2e_byte_of(m, d.crc, 8, 7) or { return error('${what}: E2ECrcSignal ${err.msg()}') }
	}
	ctr := e2e_byte_of(m, d.counter, if p05 { 8 } else { 4 }, if p05 { 7 } else { 3 }) or {
		return error('${what}: E2ECounterSignal ${err.msg()}')
	}
	if why := layout_problem(d.profile, crc, ctr) {
		return error('${what} ${why}')
	}
	return FrameE2e{
		profile:     d.profile
		data_id:     int(d.data_id)
		crc_pos:     crc
		counter_pos: ctr
		timeout_ms:  i64(d.timeout_ms)
		bad_timeout: d.bad_timeout
	}, true
}

// e2e_byte_of is the byte a field signal occupies, from its LSB: `width` bits starting at a
// byte's bit 0. A big-endian signal's start bit is its MSB, `msb` within the byte.
fn e2e_byte_of(m candb.Message, name string, width int, msb int) !int {
	if name == '' {
		return error('is not declared')
	}
	for s in m.signals {
		if s.name != name {
			continue
		}
		if s.is_multiplexor || s.is_multiplexed {
			// stamped into every frame, it would overwrite another mux branch's bits
			return error('"${name}" is multiplexed')
		}
		bit := if s.byte_order == .big_endian { msb } else { 0 }
		if s.length != width || s.start_bit % 8 != bit {
			return error('"${name}" must be ${width} bits from bit 0 of a byte')
		}
		return s.start_bit / 8
	}
	return error('"${name}" is not a signal of the frame')
}

// e2e_crc16_of is the first byte of Profile 5's CRC signal: 16 bits, little-endian (low byte
// first), from bit 0 of a byte — a big-endian one would put its high byte first.
fn e2e_crc16_of(m candb.Message, name string) !int {
	if name == '' {
		return error('is not declared')
	}
	for s in m.signals {
		if s.name != name {
			continue
		}
		if s.is_multiplexor || s.is_multiplexed {
			return error('"${name}" is multiplexed')
		}
		if s.length != 16 || s.byte_order != .little_endian || s.start_bit % 8 != 0 {
			return error('"${name}" must be 16 bits, little-endian (low byte first), from bit 0 of a byte')
		}
		return s.start_bit / 8
	}
	return error('"${name}" is not a signal of the frame')
}

// layout_problem says why a CRC at byte `crc` and a counter at byte `ctr` are not `profile`'s
// layout, if they are not: Profile 1 needs two bytes, Profile 5 its counter in the byte after
// its CRC's two (the header AUTOSAR places at one offset).
fn layout_problem(profile string, crc int, ctr int) ?string {
	if profile == candb.p05 {
		after := crc + 2
		if ctr != after {
			return 'puts the Profile 5 counter in byte ${ctr}, not in the byte after the 2-byte CRC at ${crc} (${after})'
		}
		return none
	}
	if crc == ctr {
		return 'puts the CRC and the counter in one byte (${crc})'
	}
	return none
}

// frame_e2e_profile is the profile a [[frame]].e2e `profile` value names: P01 or P05 under any
// of the spellings the DBC's E2EProfile takes (candb.profile_from_dbc), else an error.
fn frame_e2e_profile(frame string, v toml.Any) !string {
	p := if v is string { candb.profile_from_dbc(v) } else { '' }
	if p !in candb.profiles {
		return error('frame "${frame}": e2e.profile = ${v.to_toml()} is not a profile comm/e2e implements ("P01" or "P05")')
	}
	return p
}

const frame_e2e_fields = ['data_id', 'crc_pos', 'counter_pos']

// resolve_frame_e2e is a frame's effective layout: `em` is its [[frame]].e2e table (`has_toml`
// false when there is none) and `m` its DBC message, when there is one. A [[frame]].e2e field
// that contradicts the DBC is refused unless the table says `deviates_from_dbc = true`; a field
// it leaves out is the DBC's. The bool is false when neither declares E2E.
pub fn resolve_frame_e2e(frame string, has_toml bool, em map[string]toml.Any, m ?candb.Message) !(FrameE2e, bool) {
	mut declared := false
	mut dbc := FrameE2e{}
	mut dbc_err := ''
	// the DBC's E2ETimeout stands on its own: it fills a table's missing timeout whatever
	// supplies the layout (0 = none states nothing, so it binds nothing)
	mut dbc_timeout := i64(0)
	mut dbc_bad_timeout := ''
	if msg := m {
		declared = msg.e2e.declared()
		dbc_timeout = i64(msg.e2e.timeout_ms)
		dbc_bad_timeout = msg.e2e.bad_timeout
		dbc, _ = dbc_e2e(msg) or {
			dbc_err = err.msg()
			FrameE2e{}, false
		}
	}
	if !has_toml {
		if dbc_err != '' {
			return error(dbc_err)
		}
		return dbc, declared
	}
	deviates := (em['deviates_from_dbc'] or { toml.Any(false) }).bool()
	if deviates && !declared && dbc_timeout == 0 {
		// a timeout alone is still something to deviate from
		return error('frame "${frame}": e2e says deviates_from_dbc, but the DBC declares no E2E for it')
	}
	complete := frame_e2e_fields.all(it in em)
	if dbc_err != '' && !(deviates && complete) {
		// a declaration comm/e2e cannot stamp may be replaced, whole and on purpose
		return error('${dbc_err} — or give the frame a complete e2e with deviates_from_dbc = true')
	}
	if !declared && !complete {
		missing := frame_e2e_fields.filter(it !in em)
		return error('frame "${frame}": e2e has no ${missing.join(', ')}, and the DBC declares no E2E to take it from')
	}
	trusted := declared && dbc_err == '' && !deviates // the DBC's values bind the table
	// the profile: the table's, else the DBC's where it is one comm/e2e implements (a declaration
	// replaced for its layout keeps its profile), else Profile 1
	mut profile := candb.p01
	if msg := m {
		if msg.e2e.profile in candb.profiles {
			profile = msg.e2e.profile
		}
	}
	if x := em['profile'] {
		p := frame_e2e_profile(frame, x)!
		if trusted && p != profile {
			return error('frame "${frame}": e2e.profile = ${x.to_toml()} contradicts the DBC (${profile}) — ' +
				'drop it, or set deviates_from_dbc = true if the difference is deliberate')
		}
		profile = p
	} else if deviates && complete && profile != candb.p01 {
		// a complete deviating table with no profile stamped Profile 1 before Profile 5 existed,
		// so against a Profile 5 declaration it must say which it means
		return error('frame "${frame}": e2e replaces the DBC\'s ${profile} layout but states no profile — ' +
			'say e2e.profile = "P01" or "P05"')
	}
	mut v := [dbc.data_id, dbc.crc_pos, dbc.counter_pos]
	for i, k in frame_e2e_fields {
		x := em[k] or { continue }
		n := int(x.int())
		if trusted && n != v[i] {
			return error('frame "${frame}": e2e.${k} = ${n} contradicts the DBC (${v[i]}) — ' +
				'drop it, or set deviates_from_dbc = true if the difference is deliberate')
		}
		v[i] = n
	}
	mut timeout := dbc_timeout
	mut bad_timeout := dbc_bad_timeout
	if x := em['timeout_ms'] {
		// i64 throughout: the range is the generator's to refuse (ms_to_us), never a cast's to wrap
		n := x.i64()
		if !deviates && dbc_timeout > 0 && n != dbc_timeout {
			return error('frame "${frame}": e2e.timeout_ms = ${n} contradicts the DBC\'s E2ETimeout (${dbc_timeout}) — ' +
				'drop it, or set deviates_from_dbc = true if the difference is deliberate')
		}
		timeout = n
		bad_timeout = '' // a malformed DBC value binds nothing, and the table replaces it
	}
	// Profile 5's header is one place; Profile 1's distinct bytes are checked against the DLC
	// where the generator knows it
	if profile == candb.p05 {
		if why := layout_problem(profile, v[1], v[2]) {
			return error('frame "${frame}": e2e (crc_pos = ${v[1]}, counter_pos = ${v[2]}) ${why}')
		}
	}
	return FrameE2e{
		profile:     profile
		data_id:     v[0]
		crc_pos:     v[1]
		counter_pos: v[2]
		timeout_ms:  timeout
		bad_timeout: bad_timeout
	}, true
}
