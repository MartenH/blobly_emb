module app

// The first FB on the second core (multicore rung 4/5): a small LCG workload whose result
// publishes ACROSS CORES via the shared-SRAM IOC — the M7's comm/shell reads it. Pure V,
// no-alloc, same shape as every other FB in the stack.

pub struct M4Load {
pub mut:
	acc u32 = 1
	n   u32
}

// next burns a bounded LCG window and returns the running checksum — the M4's "work".
pub fn (mut l M4Load) next() u32 {
	mut a := l.acc
	for _ in 0 .. 28_000 { // ~2.2 ms at 200 MHz (bench-measured): with the stress thread's
	// ~27% this core sits near a realistic 50% — visible work, far from overrun
		a = a * 1664525 + 1013904223
	}
	l.acc = a
	l.n++
	return a
}
