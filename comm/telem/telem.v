module telem

// Telemetry: pack per-core processor load into a CAN payload so an external tool
// (e.g. the blobly_net GUI) can plot a running ECU's load over the bus. The load
// itself is measured by the Loom (loom.Scheduler.load_permille); the generated
// telemetry tx sums the per-partition figures by core and calls encode_cpuload.
// No-alloc: fixed value types only.

// Up to 8 cores fit one classic CAN frame at one byte each.
pub const cpuload_max_cores = 8

// encode_cpuload packs up to 8 per-core loads (per-mille, 0..1000) into an 8-byte
// classic CAN payload — one byte per core = load percent (0..100), clamped. Cores
// beyond `ncores` are left 0.
pub fn encode_cpuload(load_pm [cpuload_max_cores]u16, ncores int) [8]u8 {
	mut b := [8]u8{}
	n := if ncores > cpuload_max_cores { cpuload_max_cores } else { ncores }
	for i in 0 .. n {
		mut pct := u32(load_pm[i]) / 10 // per-mille -> percent
		if pct > 100 {
			pct = 100 // a core can't exceed 100% wall clock
		}
		b[i] = u8(pct)
	}
	return b
}

// decode_cpuload reads byte `core` back as a percent (the inverse of the packing),
// for tests and host-side tooling.
pub fn decode_cpuload(payload [8]u8, core int) u8 {
	if core < 0 || core >= cpuload_max_cores {
		return 0
	}
	return payload[core]
}

// pm_to_pct converts a per-mille load (0..1000) to a clamped percent (0..100).
fn pm_to_pct(load_pm u16) u8 {
	mut pct := u32(load_pm) / 10
	if pct > 100 {
		pct = 100
	}
	return u8(pct)
}

// encode_loaddetail packs one core's load over three windows plus its overrun count
// into an 8-byte payload: byte0 = load over the fast (100 ms) window, byte1 = 1 s,
// byte2 = 10 s (each a percent 0..100), byte3 = overrun count (saturating at 255).
// The fast window surfaces bursts the 1 s figure averages away; a non-zero, climbing
// overrun byte means the commanded work is exceeding the core's capacity.
pub fn encode_loaddetail(load_100ms u16, load_1s u16, load_10s u16, overruns u32) [8]u8 {
	mut b := [8]u8{}
	b[0] = pm_to_pct(load_100ms)
	b[1] = pm_to_pct(load_1s)
	b[2] = pm_to_pct(load_10s)
	b[3] = if overruns > 255 { u8(255) } else { u8(overruns) }
	return b
}

// HandlerStat frame flags.
pub const trace_flag_overran = u8(0x01) // the last invocation exceeded its period
pub const trace_flag_preempted = u8(0x02) // the handler/thread was preempted (RTOS)
pub const trace_flag_saturated = u8(0x04) // a µs field was clamped to the u16 range

// HandlerStatFrame is the decoded HandlerStat payload (for tests / host tooling).
pub struct HandlerStatFrame {
pub:
	handler_id  u8
	flags       u8
	last_us     u16
	max_us      u16
	count_delta u16
}

// encode_handlerstat packs one handler's live timing into an 8-byte HandlerStat frame:
// the global handler_id, flags, the last and max response time in microseconds (u16,
// saturating — a duration past the range is clamped and the saturated flag is set), and
// the invocations since the previous frame. All little-endian.
pub fn encode_handlerstat(handler_id u8, flags u8, last_us u32, max_us u32, count_delta u32) [8]u8 {
	mut f := flags
	mut last16 := u16(last_us)
	if last_us > 0xFFFF {
		last16 = 0xFFFF
		f |= trace_flag_saturated
	}
	mut max16 := u16(max_us)
	if max_us > 0xFFFF {
		max16 = 0xFFFF
		f |= trace_flag_saturated
	}
	cnt16 := if count_delta > 0xFFFF { u16(0xFFFF) } else { u16(count_delta) }
	mut b := [8]u8{}
	b[0] = handler_id
	b[1] = f
	b[2] = u8(last16)
	b[3] = u8(last16 >> 8)
	b[4] = u8(max16)
	b[5] = u8(max16 >> 8)
	b[6] = u8(cnt16)
	b[7] = u8(cnt16 >> 8)
	return b
}

// decode_handlerstat is the inverse (tests / host tooling).
pub fn decode_handlerstat(p [8]u8) HandlerStatFrame {
	return HandlerStatFrame{
		handler_id:  p[0]
		flags:       p[1]
		last_us:     u16(p[2]) | (u16(p[3]) << 8)
		max_us:      u16(p[4]) | (u16(p[5]) << 8)
		count_delta: u16(p[6]) | (u16(p[7]) << 8)
	}
}
