module app

// The satellite core's FBs — pure V, no-alloc, the same ports convention as every FB in
// the stack. Their cross-core signals (M4Count -> CAN via the owner, M4Stress -> the
// owner's iocx health check) are ordinary [[signal]]s in the OWNER's ecu.toml; the
// generated wrappers (gen/loom_gen.v) publish them through the xioc slots.

import ports

pub struct M4Load {
pub mut:
	acc u32 = 1
	n   u32
}

// on_10ms burns a bounded LCG window and publishes {n, acc} — the M4's "work".
pub fn (mut l M4Load) on_10ms(inp ports.M4LoadIn, mut outp ports.M4LoadOut) {
	mut a := l.acc
	for _ in 0 .. 28_000 { // ~1.7 ms at 200 MHz (bench-measured): with M4Churn's ~33%
		// this core sits near a realistic 50% — visible work, far from overrun
		a = a * 1664525 + 1013904223
	}
	l.acc = a
	l.n++
	outp.m4_count.n = l.n
	outp.m4_count.acc = a
}

pub struct M4Churn {
pub mut:
	acc u32 = 1
	k   u32
}

// on_2ms is the stress lane: LCG churn for load realism, then a monotonic {k, k*K} pair
// on the M4Stress slot. K matches XCORE_STRESS_K (xcore.h) — the owner's `iocx` command
// verifies every read satisfies chk == k*K (no tear) and k never decreases (no lap).
pub fn (mut c M4Churn) on_2ms(inp ports.M4ChurnIn, mut outp ports.M4ChurnOut) {
	mut a := c.acc
	for _ in 0 .. 8_200 { // ~0.66 ms at 200 MHz (bench-tuned): ~33% of the core at a 2 ms
		// period; with M4Load's ~17% the core sits near a realistic 50%
		a = a * 1664525 + 1013904223
	}
	c.acc = a
	c.k++
	outp.m4_stress.k = c.k
	outp.m4_stress.chk = c.k * 2654435761
}
