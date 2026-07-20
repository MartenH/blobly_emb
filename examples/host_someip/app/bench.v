module app

import sig
import ports

// Bench: publishes a counter pair onto the eth event frame — the P1-gen
// producer whose packed payload the UDP rung will put on the wire.
pub struct Bench {
pub mut:
	ticks u32
	level u8
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
		ticks: q + 0x01020304 // a live value in ALL FOUR bytes: the harness
		// proves every byte's offset/endianness (bare q keeps the top three
		// bytes zero for hours)
		wraps: u16(q + 1000) // and both bytes here (same reasoning)
	}
	// EventVal alternates 1.2 s STEPPING (every activation — faster than the
	// frame's 350 ms debounce, forcing coalescing) with 1.2 s HOLDING (the
	// frame must go SILENT — a cyclic impostor resends and fails the
	// strictly-increasing check). MixedVal steps every 7th activation: the
	// mixed frame's immediate sends between its heartbeats.
	if (fb.ticks / 12) % 2 == 0 {
		fb.level++
	}
	out.event_val = sig.EventVal{
		level: fb.level
	}
	out.mixed_val = sig.MixedVal{
		setpoint: u16(fb.ticks / 7 + 1000) // +1000: BOTH bytes live on the wire
	}
	// P2 rx round-trip: mirror the received levels — the echo on the wire
	// proves source filter -> envelope gate -> route -> (E2E check) -> unpack
	// -> publish -> app dispatch, end to end. The SUM keeps one echo frame
	// serving both rx paths (the harness uses disjoint value ranges); event
	// mode: sent only on change.
	out.echo_val = sig.EchoVal{
		level: inp.lamp_cmd.level + inp.lamp_cmd_safe.level
	}
}
