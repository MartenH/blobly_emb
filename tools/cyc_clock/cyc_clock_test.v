module main

// The core-load clock (boards/common/cyc_clock.h) on the host: the 32-bit cycle counter extended
// to 64 bits, and the microsecond clock carried beside it, which must equal floor(cycles / mhz)
// modulo 2^32 — the value the 64-bit division it replaces gave — after any sequence of advances:
// counter wraps, steps of one cycle and of nearly 2^32, and the remainder carried at its largest.

#flag -I @VMODROOT/boards/common
#include "cyc_clock.h"

@[typedef]
struct C.cyc_clock_t {
mut:
	last u32
	us   u32
	rem  u32
	cyc  u64
}

fn C.cyc_clock_advance(c &C.cyc_clock_t, now u32, mhz u32)

// held: the clock agrees with a 64-bit division of its own cycle count
fn held(c C.cyc_clock_t, mhz u32) bool {
	return u64(c.us) == (c.cyc / mhz) & 0xFFFF_FFFF && u64(c.rem) == c.cyc % mhz
}

fn test_steps_of_every_size_keep_the_division_exact() {
	for mhz in [u32(25), 200, 400, 550] {
		mut c := C.cyc_clock_t{}
		mut now := u32(0)
		mut x := u32(12345)
		for i in 0 .. 200_000 {
			x = x * 1664525 + 1013904223
			// mostly the short steps between ISRs, sometimes a long idle, rarely nearly a wrap
			step := match i % 1000 {
				999 { u32(0xFFFF_FFFF) - (x >> 20) }
				0 { x }
				else { x >> 18 }
			}
			now += step
			C.cyc_clock_advance(&c, now, mhz)
			assert held(c, mhz), 'mhz ${mhz} step ${i}: us ${c.us} rem ${c.rem} cyc ${c.cyc}'
		}
		assert c.cyc > u64(0xFFFF_FFFF) * 100, 'the 64-bit count went past many counter wraps'
	}
}

fn test_the_microsecond_clock_wraps_modulo_2_32() {
	mut c := C.cyc_clock_t{
		cyc: u64(0xFFFF_FFFF) * 400 + 399
		us:  0xFFFF_FFFF
		rem: 399
	}
	assert held(c, 400)
	C.cyc_clock_advance(&c, 801, 400)
	assert c.us == 2 && c.rem == 0
	assert held(c, 400)
}

fn test_the_counter_wrapping_is_a_step_forward() {
	mut c := C.cyc_clock_t{}
	C.cyc_clock_advance(&c, 0xFFFF_FF00, 400)
	C.cyc_clock_advance(&c, 0x100, 400)
	assert c.cyc == u64(0xFFFF_FF00) + 0x200
	assert held(c, 400)
}

fn test_the_largest_step_with_the_largest_remainder_does_not_overflow() {
	mut c := C.cyc_clock_t{}
	C.cyc_clock_advance(&c, 399, 400) // remainder 399
	assert c.rem == 399 && c.us == 0
	C.cyc_clock_advance(&c, 399 + 0xFFFF_FFFF, 400) // the counter moved 2^32 - 1
	assert c.cyc == u64(399) + 0xFFFF_FFFF
	assert held(c, 400)
}

fn test_a_still_counter_moves_nothing() {
	mut c := C.cyc_clock_t{}
	C.cyc_clock_advance(&c, 1000, 400)
	C.cyc_clock_advance(&c, 1000, 400)
	assert c.cyc == 1000 && c.us == 2 && c.rem == 200
}
