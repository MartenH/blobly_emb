module app

import sig
import ports

// GwHealth: the gateway's own voice on the telematics segment (ROADMAP rung 6). The routing is
// the comm thread's and no FB sees it, so what the gateway can honestly say from here is that it
// is up — and for how long: one count per 1000 ms activation, published cyclically as GwStatus.
// A bench reading it sees the gateway's eth path alive (and the count restart after a reset).
pub struct GwHealth {
pub mut:
	seconds u32
}

pub fn (mut fb GwHealth) on_1000ms(inp ports.GwHealthIn, mut out ports.GwHealthOut) {
	fb.seconds++
	out.gw_uptime = sig.GwUptime{
		seconds: fb.seconds
	}
}
