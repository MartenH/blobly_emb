module app

import ports

// Three pure-compute FBs at different periods, so their timings are distinct and stable
// (fast < med < slow) — the workload the handler trace measures. Each burns a controllable
// number of LCG rounds; `acc` persists in the partition state, so the work isn't optimised
// away and needs no output signal. SlowWork glitches every 40th run (~5x the work) to blow
// its budget and fire the ring trigger, so a dump shows the window around the anomaly.

fn burn(acc u32, rounds u32) u32 {
	mut a := acc
	for _ in 0 .. rounds {
		a = a * 1664525 + 1013904223
	}
	return a
}

pub struct FastWork {
pub mut:
	acc u32 = 1
}

pub fn (mut fb FastWork) on_5ms(inp ports.FastWorkIn, mut out ports.FastWorkOut) {
	fb.acc = burn(fb.acc, 3_000)
}

pub struct MedWork {
pub mut:
	acc u32 = 1
}

pub fn (mut fb MedWork) on_10ms(inp ports.MedWorkIn, mut out ports.MedWorkOut) {
	fb.acc = burn(fb.acc, 30_000)
}

pub struct SlowWork {
pub mut:
	acc u32 = 1
	n   u32
}

pub fn (mut fb SlowWork) on_20ms(inp ports.SlowWorkIn, mut out ports.SlowWorkOut) {
	fb.n++
	// Every 40th run is a glitch: ~20x the work, reliably over the trace trigger budget
	// (~ms even on a fast host) so the ring freezes and a dump shows the window around it.
	fb.acc = burn(fb.acc, if fb.n % 40 == 0 { u32(2_400_000) } else { u32(120_000) })
}
