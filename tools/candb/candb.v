// candb — minimal CAN signal database: messages, signals, and bit-level
// encode/decode. GUI-free and independently testable (see candb_test.v). This
// is the foundation the DBC phase will build on; for now signals are defined in
// code. Intel (little-endian) bit ordering only, for now.
module candb

import math

pub enum ByteOrder {
	little_endian // Intel:    start_bit = LSB, bits ascend in the LSB-0 numbering
	big_endian    // Motorola: start_bit = MSB, bits descend sawtooth across bytes
}

pub struct Signal {
pub:
	name       string
	start_bit  int // start bit (LSB for Intel, MSB for Motorola) in LSB-0 numbering
	length     int // width in bits
	factor     f64 = 1.0
	offset     f64
	minimum    f64 // physical range from the DBC [min|max] (0,0 if unspecified)
	maximum    f64
	unit       string
	desc       string            // human-readable description / interpretation
	receivers  []string          // DBC RX nodes (the SG_ trailing node list; '' / Vector__XXX = none)
	values     map[u64]string    // DBC VAL_ table: raw value -> named state (enum)
	is_signed  bool
	byte_order ByteOrder = .little_endian
	// Multiplexing (DBC 'M' / 'm<N>'): a message may have ONE multiplexor switch
	// signal; multiplexed signals are only present when the switch equals their
	// selector value. is_multiplexor and is_multiplexed can both be true for
	// extended multiplexing ('m<N>M').
	is_multiplexor bool // 'M' — selects which multiplexed signals are present
	is_multiplexed bool // 'm<N>' — present only when the switch == multiplexor_value
	multiplexor_value int // the N in 'm<N>'
}

// label returns the VAL_ table name for the signal's current raw value in
// `data` (e.g. Gear 3 -> "Third"), or '' if the signal has no value table /
// no entry for that value.
pub fn (s Signal) label(data []u8) string {
	return s.values[s.raw_value(data)]
}

pub struct Message {
pub:
	name     string
	id       u32
	ext      bool   // 29-bit extended identifier (DBC EFF high-bit was set)
	dlc      int
	sender   string // transmitting node (DBC BO_ transmitter); '' / 'Vector__XXX' = none
	cycle_ms int    // GenMsgCycleTime attribute if present (0 = not cyclic / unknown)
	signals  []Signal
	e2e      E2eDecl // blobly_net#271's E2E contract attributes, as the file states them
}

// E2eDecl is a message's E2E contract as the DBC declares it through the attributes blobly_net
// defines in docs/dbc_attributes.md (E2ECounterSignal, E2ECrcSignal, E2EProfile, E2EDataId,
// E2ETimeout) — parsed as blobly_net's candb parses them, so both repos read one file the same way.
pub struct E2eDecl {
pub mut:
	counter     string
	crc         string
	profile     string // normalised: Profile 1 is 'autosar_p01' however the file spells it
	data_id     u32
	has_data_id bool   // 0 is a legitimate Data ID, so presence is its own fact
	bad_data_id string // an E2EDataId the file wrote that is not a Data ID — never read as absent
	timeout_ms  u32    // E2ETimeout: the receiver's sender-loss timeout, 0 meaning none
	has_timeout bool   // stated per message (0 included)
	bad_timeout string // an E2ETimeout that is not a number of ms
}

// profile_from_dbc is the profile an `E2EProfile` value names: Profile 1 under any of its
// spellings — `P01`, AUTOSAR's `PROFILE_01`, and `autosar_p01` — and anything else as written.
pub fn profile_from_dbc(v string) string {
	return if v in ['P01', 'PROFILE_01', 'autosar_p01'] { 'autosar_p01' } else { v }
}

pub fn (d E2eDecl) declared() bool {
	return d.counter != '' || d.crc != '' || d.profile != '' || d.has_data_id || d.bad_data_id != ''
}

// raw_value extracts the unsigned raw bits of the signal from `data`. Handles
// both Intel (little-endian) and Motorola (big-endian) bit ordering. Bits use
// the LSB-0 numbering: position p -> byte p/8, bit p%8 (bit 0 = byte LSB).
pub fn (s Signal) raw_value(data []u8) u64 {
	mut raw := u64(0)
	if s.byte_order == .little_endian {
		for i in 0 .. s.length {
			g := s.start_bit + i
			byte_idx := g / 8
			bit_idx := g % 8
			if byte_idx >= data.len {
				continue
			}
			bit := (data[byte_idx] >> bit_idx) & 1
			raw |= u64(bit) << i
		}
	} else {
		// Motorola: start_bit is the MSB; walk MSB->LSB, dropping to the next
		// byte's bit 7 each time we fall off the bottom of a byte (sawtooth).
		mut pos := s.start_bit
		for _ in 0 .. s.length {
			byte_idx := pos / 8
			bit_idx := pos % 8
			raw <<= 1
			if byte_idx < data.len {
				raw |= u64((data[byte_idx] >> bit_idx) & 1)
			}
			pos = if bit_idx == 0 { pos + 15 } else { pos - 1 }
		}
	}
	return raw
}

// physical applies sign-extension, factor and offset: phys = raw * factor + offset.
pub fn (s Signal) physical(data []u8) f64 {
	raw := s.raw_value(data)
	mut v := f64(raw)
	if s.is_signed && s.length > 0 && s.length < 64 {
		sign_bit := u64(1) << (s.length - 1)
		if raw & sign_bit != 0 {
			v = f64(i64(raw) - i64(u64(1) << s.length)) // two's-complement negative
		}
	}
	return v * s.factor + s.offset
}

// set_raw writes `raw` into `data` at the signal's bit position. Mirrors
// raw_value for both Intel (little-endian) and Motorola (big-endian) ordering.
pub fn (s Signal) set_raw(mut data []u8, raw u64) {
	if s.byte_order == .little_endian {
		for i in 0 .. s.length {
			g := s.start_bit + i
			byte_idx := g / 8
			bit_idx := g % 8
			if byte_idx >= data.len {
				continue
			}
			mask := u8(1) << bit_idx
			bit := u8((raw >> i) & 1)
			data[byte_idx] = (data[byte_idx] & ~mask) | (bit << bit_idx)
		}
	} else {
		// Motorola: write MSB-first along the same sawtooth as raw_value.
		mut pos := s.start_bit
		for i in 0 .. s.length {
			byte_idx := pos / 8
			bit_idx := pos % 8
			bit := u8((raw >> (s.length - 1 - i)) & 1)
			if byte_idx < data.len {
				mask := u8(1) << bit_idx
				data[byte_idx] = (data[byte_idx] & ~mask) | (bit << bit_idx)
			}
			pos = if bit_idx == 0 { pos + 15 } else { pos - 1 }
		}
	}
}

// encode converts a physical value to raw and writes it into `data`.
pub fn (s Signal) encode(mut data []u8, phys f64) {
	// round half away from zero; a bare `+ 0.5` truncates negatives wrongly.
	mut raw := i64(math.round((phys - s.offset) / s.factor))
	if raw < 0 {
		raw += i64(u64(1) << s.length)
	}
	mask := if s.length >= 64 { ~u64(0) } else { (u64(1) << s.length) - 1 }
	s.set_raw(mut data, u64(raw) & mask)
}

// owns reports whether global bit index `g` (LSB-0 numbering) belongs to this
// signal. Little-endian signals occupy a contiguous range; big-endian (Motorola)
// signals zig-zag across bytes, so we walk the sawtooth to test membership.
pub fn (s Signal) owns(g int) bool {
	if s.byte_order == .little_endian {
		return g >= s.start_bit && g < s.start_bit + s.length
	}
	mut pos := s.start_bit
	for _ in 0 .. s.length {
		if pos == g {
			return true
		}
		pos = if pos % 8 == 0 { pos + 15 } else { pos - 1 }
	}
	return false
}

// signal_at returns the index of the signal owning global bit `g`, or -1.
pub fn (m Message) signal_at(g int) int {
	for i, s in m.signals {
		if s.owns(g) {
			return i
		}
	}
	return -1
}

// multiplexor_index returns the index of the message's multiplexor switch
// signal ('M'), or -1 if the message is not multiplexed.
pub fn (m Message) multiplexor_index() int {
	for i, s in m.signals {
		if s.is_multiplexor {
			return i
		}
	}
	return -1
}

// active_signals returns the signals actually present in `data`: every
// non-multiplexed signal, plus the multiplexed signals whose selector matches
// the current value of the multiplexor switch. For a non-multiplexed message it
// returns all signals unchanged.
pub fn (m Message) active_signals(data []u8) []Signal {
	mux_idx := m.multiplexor_index()
	if mux_idx < 0 {
		return m.signals
	}
	mux_val := m.signals[mux_idx].raw_value(data)
	mut out := []Signal{}
	for s in m.signals {
		if !s.is_multiplexed || u64(s.multiplexor_value) == mux_val {
			out << s
		}
	}
	return out
}

// RawRange is what a sent value may become on the wire, in raw steps: the signal's declared
// [min|max] intersected with what its width holds. `lo` / `hi` are its ends as f64 whole numbers and
// `lo_raw` / `hi_raw` their exact bit patterns (past 2^53 an f64 cannot hold every integer: a 64-bit
// width's top, 2^64 - 1, is the f64 2^64, and comm/com `encode_raw` answers that end with its bits).
// `nan_raw` is raw 0 brought into the range. `named` are the VAL_ entries outside the range — a
// value the database names (0xFF "not available" on a [0|250] signal) is sent as is, never held to
// the range. `note` says why the declared range is not used, where it cannot be ('' = it is).
pub struct RawRange {
pub:
	lo      f64
	hi      f64
	lo_raw  u64
	hi_raw  u64
	nan_raw u64
	mask    u64
	named   []NamedRaw
	note    string
}

// NamedRaw is a VAL_ entry outside the range: its value in raw steps and its bits.
pub struct NamedRaw {
pub:
	steps f64
	raw   u64
	label string
}

// encode_lines: generated V that encodes the f64 expression `phys` into `raw` (u64 bits, masked to the
// width) and `sat` (whether it was held to the range) through comm/com `encode_raw` — THE one send
// encode (docs/communication.md "Sent values outside the signal range"), shared by dbc2cfg's `_set`
// and loom2v's target producers so both put the same bits on the wire. `raw` also names the scratch
// value in raw steps (`<raw>_x`). A VAL_ entry outside the range is let through as itself.
pub fn (s Signal) encode_lines(phys string, raw string, sat string, ind string) ![]string {
	r := s.raw_range()!
	x := '${raw}_x'
	mut g := ['${ind}${x} := (${phys} - ${f64lit(s.offset)}) / ${f64lit(s.factor)}']
	call := 'com.encode_raw(${x}, ${int_f64lit(r.lo)}, ${int_f64lit(r.hi)}, u64(${r.lo_raw}), u64(${r.hi_raw}), u64(${r.nan_raw}), u64(0x${r.mask.hex()}))'
	if r.named.len == 0 {
		g << '${ind}${raw}, ${sat} := ${call}'
		return g
	}
	g << '${ind}mut ${raw}, mut ${sat} := ${call}'
	for n in r.named {
		g << '${ind}if ${sat} && com.round_steps(${x}) == ${int_f64lit(n.steps)} { // VAL_ "${n.label}": outside the range, sent as named'
		g << '${ind}\t${raw} = u64(${n.raw})'
		g << '${ind}\t${sat} = false'
		g << '${ind}}'
	}
	return g
}

// f64lit renders an f64 as a valid V float literal (always with a decimal point).
fn f64lit(x f64) string {
	t := x.str()
	if t.contains('.') || t.contains('e') || t.contains('E') {
		return t
	}
	return t + '.0'
}

// int_f64lit: a whole-number f64 as the V literal of exactly that integer (a shortest decimal
// spelling of a large one could read back as a neighbour).
fn int_f64lit(x f64) string {
	if x >= 18446744073709551616.0 {
		return '18446744073709551616.0' // 2^64: the f64 a 64-bit width's top rounds to
	}
	return if x < 0 { '${i64(x)}.0' } else { '${u64(x)}.0' }
}

// raw_range: a signal's sendable raw values — what comm/com `encode_raw` holds a sent value to
// (docs/communication.md "Sent values outside the signal range"). A DBC range of [0|0] declares none
// (the width is the range); a declared range is converted to raw steps — ceil of the minimum, floor of
// the maximum, so an end that is not on the raw grid is never passed — with a few ULPs of tolerance
// for the division's own rounding (0.3 / 0.1 is 2.9999999999999996, and must be 3). A declared
// range that cannot be used — factor 0, minimum above maximum, no raw value inside the width — leaves
// the width, said in `note` (loom2v refuses it on a signal a node sends; dbc2cfg warns).
pub fn (s Signal) raw_range() !RawRange {
	n := s.length
	if n < 1 || n > 64 {
		return error('${n} bits — a signal is 1..64 bits')
	}
	mask := if n == 64 { ~u64(0) } else { (u64(1) << n) - 1 }
	mut wlo := 0.0
	mut wlo_raw := u64(0)
	mut whi_raw := mask
	if s.is_signed {
		top := u64(1) << (n - 1)
		wlo = -f64(top) // a power of two: exact
		wlo_raw = top // -2^(n-1), masked to the width
		whi_raw = top - 1
	}
	whi := f64(whi_raw) // exact below 2^53; above, the nearest f64 (encode_raw answers it with whi_raw)
	mut lo := wlo
	mut hi := whi
	mut note := ''
	if s.factor == 0.0 {
		note = 'factor 0: no physical value maps back to a raw one'
	} else if s.minimum > s.maximum {
		note = 'range [${s.minimum}|${s.maximum}] has its minimum above its maximum'
	} else if s.minimum != 0.0 || s.maximum != 0.0 {
		mut a := (s.minimum - s.offset) / s.factor
		mut z := (s.maximum - s.offset) / s.factor
		if s.factor < 0 {
			a, z = z, a
		}
		rl := math.max(math.ceil(a - grid_tol(a)), wlo)
		rh := math.min(math.floor(z + grid_tol(z)), whi)
		if rl > rh {
			note = 'range [${s.minimum}|${s.maximum}] holds no raw value the ${n}-bit width carries'
		} else {
			lo, hi = rl, rh
		}
	}
	lo_raw := if lo == wlo { wlo_raw } else { exact_raw(lo, mask) }
	hi_raw := if hi == whi { whi_raw } else { exact_raw(hi, mask) }
	nan_raw := if lo > 0 {
		lo_raw
	} else if hi < 0 {
		hi_raw
	} else {
		u64(0)
	}
	mut named := []NamedRaw{}
	mut keys := s.values.keys()
	keys.sort()
	for k in keys {
		if k > mask {
			continue // not a value of this width
		}
		steps := if s.is_signed && n < 64 && k & (u64(1) << (n - 1)) != 0 {
			f64(i64(k | ~mask)) // sign-extended
		} else if s.is_signed {
			f64(i64(k))
		} else {
			f64(k)
		}
		if steps < lo || steps > hi {
			named << NamedRaw{
				steps: steps
				raw:   k
				label: s.values[k] or { '' }
			}
		}
	}
	return RawRange{
		lo:      lo
		hi:      hi
		lo_raw:  lo_raw
		hi_raw:  hi_raw
		nan_raw: nan_raw
		mask:    mask
		named:   named
		note:    note
	}
}

// grid_tol: how far a quotient may sit off the raw grid by the division's rounding alone — a few
// ULPs of it, never a fraction of a raw step that a real value could occupy.
fn grid_tol(q f64) f64 {
	return 4.0 * 2.220446049250313e-16 * math.max(1.0, math.abs(q))
}

// exact_raw: a whole-number f64 inside the width as its raw bits (two's complement when negative).
fn exact_raw(x f64, mask u64) u64 {
	return if x < 0 { u64(i64(x)) & mask } else { u64(x) & mask }
}
