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
