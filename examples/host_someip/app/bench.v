module app

import sig
import ports

// Bench: publishes a counter pair onto the eth event frame — the P1-gen
// producer whose packed payload the UDP rung will put on the wire.
pub struct Bench {
pub mut:
	ticks u32
}

pub fn (mut fb Bench) on_100ms(inp ports.BenchIn, mut out ports.BenchOut) {
	fb.ticks++
	out.bench_load = sig.BenchLoad{
		load: u8(fb.ticks % 100)
	}
	out.bench_ticks = sig.BenchTicks{
		ticks: fb.ticks
		wraps: u16(fb.ticks >> 16)
	}
	// step every 5th/7th activation: the event frame's ONLY sends, and the
	// mixed frame's immediate sends between its heartbeats
	out.event_val = sig.EventVal{
		level: u8(fb.ticks / 5)
	}
	out.mixed_val = sig.MixedVal{
		setpoint: u16(fb.ticks / 7)
	}
}
