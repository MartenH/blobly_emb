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
	// quantized to every 4th activation: the cyclic frame RESENDS an unchanged
	// layout 3 of 4 cycles — the harness needs an interval where cyclic
	// retransmits without change (that is what distinguishes it from event)
	q := fb.ticks / 4
	out.bench_load = sig.BenchLoad{
		load: u8(q % 100)
	}
	out.bench_ticks = sig.BenchTicks{
		ticks: q
		wraps: u16(q + 1000) // always nonzero in BOTH bytes: the harness proves
		// the field's offset/endianness with live values (q>>16 is 0 for hours)
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
