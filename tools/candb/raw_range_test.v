module candb

// @verifies REQ-COM-010

fn sig(start int, len int, signed bool, factor f64, offset f64, min f64, max f64) Signal {
	return Signal{
		name:      'S'
		start_bit: start
		length:    len
		is_signed: signed
		factor:    factor
		offset:    offset
		minimum:   min
		maximum:   max
	}
}

// The range a sent value is saturated to: the declared [min|max] in raw steps, inside the width.
fn test_raw_range_is_the_declared_range_inside_the_width() {
	// [0|100] on 8 bits, factor 1
	r := sig(0, 8, false, 1, 0, 0, 100).raw_range()!
	assert r.lo == 0.0 && r.hi == 100.0 && r.lo_raw == 0 && r.hi_raw == 100 && r.mask == 0xFF
	// [0|0] declares no range: the width is the range
	w := sig(0, 8, true, 1, 0, 0, 0).raw_range()!
	assert w.lo == -128.0 && w.hi == 127.0 && w.lo_raw == 0x80 && w.hi_raw == 0x7F && w.nan_raw == 0
	// a range wider than the width is cut to it
	c := sig(0, 8, false, 1, 0, -50, 1000).raw_range()!
	assert c.lo == 0.0 && c.hi == 255.0 && c.hi_raw == 0xFF
	// factor and offset: [-40|87.5] at (0.5, -40) is raw 0..255
	t := sig(0, 8, false, 0.5, -40, -40, 87.5).raw_range()!
	assert t.lo == 0.0 && t.hi == 255.0
	// signed and scaled: [-3276.8|3276.7] at 0.1 is the whole 16-bit range
	q := sig(0, 16, true, 0.1, 0, -3276.8, 3276.7).raw_range()!
	assert q.lo == -32768.0 && q.hi == 32767.0 && q.lo_raw == 0x8000 && q.hi_raw == 0x7FFF
	// 0.3 / 0.1 is 2.9999999999999996 in f64: still raw 3
	g := sig(0, 8, false, 0.1, 0, 0, 0.3).raw_range()!
	assert g.hi == 3.0
	// an end off the raw grid is never passed: [0.05|10.03] at 0.1 is raw 1..100
	o := sig(0, 8, false, 0.1, 0, 0.05, 10.03).raw_range()!
	assert o.lo == 1.0 && o.hi == 100.0 && o.nan_raw == 1
	// a negative factor turns the range over
	n := sig(0, 8, true, -1, 0, -10, 5).raw_range()!
	assert n.lo == -5.0 && n.hi == 10.0 && n.lo_raw == 0xFB
	// 64 bits: the f64 ends are inside the range, the raw ends exact
	u := sig(0, 64, false, 1, 0, 0, 0).raw_range()!
	assert u.hi == 18446744073709551616.0 && u.hi_raw == ~u64(0) && u.mask == ~u64(0)
	s := sig(0, 64, true, 1, 0, 0, 0).raw_range()!
	assert s.lo == -9223372036854775808.0 && s.hi == 9223372036854775808.0
	assert s.lo_raw == u64(1) << 63 && s.hi_raw == (u64(1) << 63) - 1
	assert int_f64lit(u.hi) == '18446744073709551616.0' && int_f64lit(s.lo) == '-9223372036854775808.0'
	assert int_f64lit(s.hi) == '9223372036854775808.0'
	// a large range is not widened by the tolerance: [0|4000000000] ends at 4000000000
	big := sig(0, 32, false, 1, 0, 0, 4000000000).raw_range()!
	assert big.hi == 4000000000.0 && big.hi_raw == 4000000000
}

// A range no value could be sent in leaves the width, and says why (loom2v refuses it on a sent signal).
fn test_a_range_no_value_fits_leaves_the_width_and_says_so() {
	for s in [sig(0, 8, false, 1, 0, 300, 400), sig(0, 8, false, 1, 0, 10, 5), sig(0, 8, false, 0, 0, 0, 10)] {
		r := s.raw_range()!
		assert r.note != ''
		assert r.lo == 0.0 && r.hi == 255.0
	}
	assert sig(0, 8, false, 1, 0, 0, 100).raw_range()!.note == ''
	if _ := sig(0, 0, false, 1, 0, 0, 0).raw_range() {
		assert false, 'a zero-width signal'
	}
}

// A VAL_ entry outside the range is a value the database names (0xFF "SNA"): let through, not held.
fn test_named_values_outside_the_range_are_listed() {
	s := Signal{
		name:    'S'
		length:  8
		maximum: 250
		values:  {
			u64(0):   'Zero'
			u64(255): 'SNA'
		}
	}
	r := s.raw_range()!
	assert r.named.len == 1 && r.named[0].raw == 255 && r.named[0].steps == 255.0
	n := Signal{
		name:      'N'
		length:    8
		is_signed: true
		minimum:   -100
		maximum:   100
		values:    {
			u64(0x80): 'Invalid'
		}
	}
	assert n.raw_range()!.named[0].steps == -128.0
	lines := s.encode_lines('phys', 'raw', 'sat', '')!
	assert lines[1] == 'mut raw, mut sat := com.encode_raw(raw_x, 0.0, 250.0, u64(0), u64(250), u64(0), u64(0xff))'
	assert lines[2] == 'if sat && com.round_steps(raw_x) == 255.0 { // VAL_ "SNA": outside the range, sent as named'
}
