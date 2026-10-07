module com

// two_52: from here on an f64 holds no fraction, so it is already a whole number of raw steps.
const two_52 = 4503599627370496.0

// encode_raw is the ONE rule that turns a sent value into a signal's raw bits — every generated
// `<frame>_<signal>_set` calls it, and so does the target comm thread's producer (both emitted by
// tools/candb encode_lines), so the host bridge, a gateway's signal route and the target put the same
// bits on the wire for the same value.
//
// `x` is the value in raw steps, (phys - offset) / factor. It is rounded half away from zero, then
// SATURATED to [lo, hi]: the signal's declared [min|max] in raw steps, already intersected with what
// its bit width holds (tools/candb raw_range computes both). A value outside is sent as the nearest end of
// the range instead of wrapping into the bits, and the second result says so — the caller counts it
// (docs/communication.md "Sent values outside the signal range"). `lo` / `hi` are those bounds as
// f64 and `lo_raw` / `hi_raw` their exact bit patterns, which is what an end and an out-of-range value
// get (past 2^53 an f64 cannot hold every integer: a 64-bit width's top, 2^64 - 1, is the f64 2^64, so
// a value rounding there is that end, not past it). NaN carries no value:
// it is sent as `nan_raw` (raw 0, the value an unwritten frame holds, brought into the range) and
// counts as saturated. A rounded value inside the range is never saturated, so 100.04 on a [0|100]
// signal of factor 1 goes out as 100 and is not counted: it is the value the rounding gives anyway.
pub fn encode_raw(x f64, lo f64, hi f64, lo_raw u64, hi_raw u64, nan_raw u64, mask u64) (u64, bool) {
	if x != x {
		return nan_raw, true
	}
	r := round_steps(x)
	if r < lo {
		return lo_raw, true
	}
	if r > hi {
		return hi_raw, true
	}
	// an end is answered with its exact bits: a 64-bit width's top, 2^64 - 1, is the f64 2^64
	if r == lo {
		return lo_raw, false
	}
	if r == hi {
		return hi_raw, false
	}
	// strictly inside, so r is a whole number the width holds: the casts are exact
	if r < 0 {
		return u64(i64(r)) & mask, false
	}
	return u64(r) & mask, false
}

// round_steps rounds a value in raw steps half away from zero (an f64 past 2^52 is already whole).
pub fn round_steps(x f64) f64 {
	if x > -two_52 && x < two_52 {
		t := f64(i64(x))
		d := x - t // exact: t is x's integer part
		return if d >= 0.5 {
			t + 1.0
		} else if d <= -0.5 {
			t - 1.0
		} else {
			t
		}
	}
	return x
}

// TxSaturations counts the sent values `encode_raw` had to saturate: one per signal value in a frame
// the channel accepted. It saturates itself at the top of a u32 rather than wrap to a small count.
// One per encoding context, written by that context only (the bridge that owns a bus, the target's
// comm thread); the node's `tx_saturations` DID reads it.
pub struct TxSaturations {
pub mut:
	count u32
}

// add counts `n` saturated values.
pub fn (mut s TxSaturations) add(n u32) {
	s.count = if s.count > max_u32 - n { max_u32 } else { s.count + n }
}
