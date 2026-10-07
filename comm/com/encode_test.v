module com

// @verifies REQ-COM-010

import math

// enc: encode_raw with the bounds of an n-bit signal whose declared range is [lo, hi] raw steps
// (the arguments dbc2cfg emits, for a range inside 2^53).
struct Enc {
	raw u64
	sat bool
}

fn er(x f64, lo f64, hi f64, lo_raw u64, hi_raw u64, nan_raw u64, mask u64) Enc {
	raw, sat := encode_raw(x, lo, hi, lo_raw, hi_raw, nan_raw, mask)
	return Enc{raw, sat}
}

fn enc(x f64, lo i64, hi i64, n int) Enc {
	mask := if n == 64 { ~u64(0) } else { (u64(1) << n) - 1 }
	lo_raw := u64(lo) & mask
	hi_raw := u64(hi) & mask
	nan_raw := if lo > 0 {
		lo_raw
	} else if hi < 0 {
		hi_raw
	} else {
		u64(0)
	}
	return er(x, f64(lo), f64(hi), lo_raw, hi_raw, nan_raw, mask)
}

fn test_in_range_values_round_half_away_from_zero() {
	assert enc(42.0, 0, 100, 8) == Enc{u64(42), false}
	assert enc(42.5, 0, 100, 8) == Enc{u64(43), false}
	assert enc(42.49, 0, 100, 8) == Enc{u64(42), false}
	assert enc(-2.5, -128, 127, 8) == Enc{u64(0xFD), false} // -3, two's complement
	assert enc(-2.49, -128, 127, 8) == Enc{u64(0xFE), false}
	// the classic +0.5 trap: 0.49999999999999994 + 0.5 rounds to 1.0 in f64
	assert enc(0.49999999999999994, 0, 100, 8) == Enc{u64(0), false}
}

fn test_the_ends_of_the_range_are_sent_as_is() {
	assert enc(0.0, 0, 100, 8) == Enc{u64(0), false}
	assert enc(100.0, 0, 100, 8) == Enc{u64(100), false}
	assert enc(-128.0, -128, 127, 8) == Enc{u64(0x80), false}
	assert enc(127.0, -128, 127, 8) == Enc{u64(0x7F), false}
	// within half a step of an end, the rounding lands on it: not a saturation
	assert enc(100.4, 0, 100, 8) == Enc{u64(100), false}
	assert enc(-0.4, 0, 100, 8) == Enc{u64(0), false}
}

fn test_beyond_the_declared_range_saturates() {
	// 150 on an 8-bit [0|100] signal fits the width — once sent as 150, now 100
	assert enc(150.0, 0, 100, 8) == Enc{u64(100), true}
	assert enc(100.5, 0, 100, 8) == Enc{u64(100), true}
	assert enc(-1.0, 0, 100, 8) == Enc{u64(0), true}
	assert enc(-0.5, 0, 100, 8) == Enc{u64(0), true}
	assert enc(-40.0, -30, 30, 8) == Enc{u64(0xE2), true} // -30
	assert enc(31.0, -30, 30, 8) == Enc{u64(30), true}
}

fn test_beyond_the_width_saturates_instead_of_wrapping() {
	// 300 into 8 bits wrapped to 44, and -1 into an unsigned signal to 255
	assert enc(300.0, 0, 255, 8) == Enc{u64(255), true}
	assert enc(-1.0, 0, 255, 8) == Enc{u64(0), true}
	assert enc(200.0, -128, 127, 8) == Enc{u64(0x7F), true}
	assert enc(-200.0, -128, 127, 8) == Enc{u64(0x80), true}
	assert enc(1e30, 0, 0xFFFF, 16) == Enc{u64(0xFFFF), true}
	assert enc(-1e30, -32768, 32767, 16) == Enc{u64(0x8000), true}
}

fn test_infinities_saturate_and_nan_goes_out_as_zero_in_range() {
	assert enc(math.inf(1), 0, 100, 8) == Enc{u64(100), true}
	assert enc(math.inf(-1), 0, 100, 8) == Enc{u64(0), true}
	assert enc(math.nan(), 0, 100, 8) == Enc{u64(0), true}
	assert enc(math.nan(), -128, 127, 8) == Enc{u64(0), true}
	// raw 0 outside the range: the end nearest it
	assert enc(math.nan(), 10, 100, 8) == Enc{u64(10), true}
	assert enc(math.nan(), -100, -10, 8) == Enc{u64(0xF6), true}
}

fn test_a_64_bit_signal_saturates_at_its_exact_ends() {
	// unsigned 64: the top, 2^64 - 1, is the f64 2^64 — a value rounding there IS the top, sent as
	// its exact bits and not counted; past it, saturated
	hi := 18446744073709551616.0
	assert er(1.8446744073709552e19, 0.0, hi, 0, ~u64(0), 0, ~u64(0)) == Enc{~u64(0), false}
	assert er(1.8446744073709556e19, 0.0, hi, 0, ~u64(0), 0, ~u64(0)) == Enc{~u64(0), true}
	assert er(18446744073709549568.0, 0.0, hi, 0, ~u64(0), 0, ~u64(0)) == Enc{u64(18446744073709549568), false}
	assert er(1e19, 0.0, hi, 0, ~u64(0), 0, ~u64(0)) == Enc{u64(10000000000000000000), false}
	assert er(-1.0, 0.0, hi, 0, ~u64(0), 0, ~u64(0)) == Enc{u64(0), true}
	// signed 64: [-2^63, 2^63 - 1], the top the f64 2^63
	shi := 9223372036854775808.0
	slo := -9223372036854775808.0
	top := u64(1) << 63
	assert er(shi, slo, shi, top, top - 1, 0, ~u64(0)) == Enc{top - 1, false}
	assert er(9.3e18, slo, shi, top, top - 1, 0, ~u64(0)) == Enc{top - 1, true}
	assert er(-9.3e18, slo, shi, top, top - 1, 0, ~u64(0)) == Enc{top, true}
	assert er(slo, slo, shi, top, top - 1, 0, ~u64(0)) == Enc{top, false}
	assert er(-1.0, slo, shi, top, top - 1, 0, ~u64(0)) == Enc{~u64(0), false}
}

fn test_round_steps() {
	assert round_steps(2.5) == 3.0
	assert round_steps(-2.5) == -3.0
	assert round_steps(2.4999) == 2.0
	assert round_steps(0.49999999999999994) == 0.0
	assert round_steps(1e300) == 1e300
}

fn test_saturations_count_and_never_wrap() {
	mut s := TxSaturations{}
	s.add(0)
	assert s.count == 0
	s.add(2)
	assert s.count == 2
	s.count = max_u32 - 1
	s.add(5)
	assert s.count == max_u32
	s.add(1)
	assert s.count == max_u32
}
