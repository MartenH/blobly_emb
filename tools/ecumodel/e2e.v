module ecumodel

import toml
import tools.candb

// e2e.v — a CAN frame's effective E2E layout: its [[frame]].e2e, else what the DBC declares
// through blobly_net#271's attributes. ONE resolution, so every tool that asks agrees.

// FrameE2e is where comm/e2e stamps a frame: the Data ID, the CRC byte, and the byte whose
// low nibble is the counter.
pub struct FrameE2e {
pub:
	data_id     int
	crc_pos     int
	counter_pos int
}

// dbc_e2e is the layout the DBC declares for `m`, refused where comm/e2e cannot stamp it:
// a profile other than autosar_p01 (the only one it implements), a missing or out-of-range
// Data ID, or signals that are not an 8-bit byte-aligned CRC and a 4-bit counter in a byte's low
// nibble. The bool is false when the DBC declares nothing.
pub fn dbc_e2e(m candb.Message) !(FrameE2e, bool) {
	d := m.e2e
	if !d.declared() {
		return FrameE2e{}, false
	}
	what := 'frame "${m.name}": the DBC\'s E2E declaration'
	if d.profile != 'autosar_p01' {
		return error('${what} names profile "${d.profile}" — only autosar_p01 is implemented')
	}
	if d.bad_data_id != '' {
		return error('${what} has E2EDataId "${d.bad_data_id}", which is not a Data ID')
	}
	if !d.has_data_id || d.data_id > 0xFFFF {
		return error('${what} needs an E2EDataId in 0..0xFFFF')
	}
	crc := e2e_byte_of(m, d.crc, 8, 7) or { return error('${what}: E2ECrcSignal ${err.msg()}') }
	ctr := e2e_byte_of(m, d.counter, 4, 3) or {
		return error('${what}: E2ECounterSignal ${err.msg()}')
	}
	if crc == ctr {
		return error('${what} puts the CRC and the counter in one byte (${crc})')
	}
	return FrameE2e{
		data_id:     int(d.data_id)
		crc_pos:     crc
		counter_pos: ctr
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
		bit := if s.byte_order == .big_endian { msb } else { 0 }
		if s.length != width || s.start_bit % 8 != bit {
			return error('"${name}" must be ${width} bits from bit 0 of a byte')
		}
		return s.start_bit / 8
	}
	return error('"${name}" is not a signal of the frame')
}

const frame_e2e_fields = ['data_id', 'crc_pos', 'counter_pos']

// resolve_frame_e2e is a frame's effective layout: `em` is its [[frame]].e2e table (`has_toml`
// false when there is none) and `m` its DBC message, when there is one. A [[frame]].e2e field
// that contradicts the DBC is refused unless the table says `deviates_from_dbc = true`; a field
// it leaves out is the DBC's. The bool is false when neither declares E2E.
pub fn resolve_frame_e2e(frame string, has_toml bool, em map[string]toml.Any, m ?candb.Message) !(FrameE2e, bool) {
	mut dbc := FrameE2e{}
	mut has_dbc := false
	if msg := m {
		dbc, has_dbc = dbc_e2e(msg)!
	}
	if !has_toml {
		return dbc, has_dbc
	}
	deviates := (em['deviates_from_dbc'] or { toml.Any(false) }).bool()
	if deviates && !has_dbc {
		return error('frame "${frame}": e2e says deviates_from_dbc, but the DBC declares no E2E for it')
	}
	mut v := [dbc.data_id, dbc.crc_pos, dbc.counter_pos]
	for i, k in frame_e2e_fields {
		x := em[k] or { continue }
		n := int(x.int())
		if has_dbc && !deviates && n != v[i] {
			return error('frame "${frame}": e2e.${k} = ${n} contradicts the DBC (${v[i]}) — ' +
				'drop it, or set deviates_from_dbc = true if the difference is deliberate')
		}
		v[i] = n
	}
	return FrameE2e{
		data_id:     v[0]
		crc_pos:     v[1]
		counter_pos: v[2]
	}, true
}
