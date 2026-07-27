module app

import sig
import ports

// Bench: the host_someip / h735_someip producer carried to the H723 telematics node —
// quantized counters on the cyclic E2E-protected SOME/IP frame, and the rx round trip
// mirrored on the echo. Identical wire to the host oracle, so the same listener
// verifies the H723 eth path (docs/someip.md target rung).
pub struct Bench {
pub mut:
	ticks u32
}

pub fn (mut fb Bench) on_100ms(inp ports.BenchIn, mut out ports.BenchOut) {
	fb.ticks++
	// quantized to every 4th activation: cyclic resends an unchanged layout
	// 3 of 4 cycles (the mode's distinguishing behavior, as on host)
	q := fb.ticks / 4
	out.bench_load = sig.BenchLoad{
		load: u8(q % 100)
	}
	out.bench_ticks = sig.BenchTicks{
		ticks: q + 0x01020304 // live value in ALL FOUR bytes (offset/endianness proof)
		wraps: u16(q + 1000)
	}
	// the rx round trip: mirror the last received LampCmd level — an echo on the
	// wire proves the whole silicon rx chain (docs/someip.md target rung)
	out.echo_val = sig.EchoVal{
		level: inp.lamp_cmd.level
	}
}
