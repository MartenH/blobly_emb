module trace

import driver.can

// Host multi-core trace (P3a, docs/trace-multicore.md §3): one dump owner, N producing cores.
//
// The owner is an ordinary app partition — it runs its own handlers, so its ring is genuinely
// LOCAL (m.buf) and the existing single-core path serves it unchanged. A second partition on
// another core writes its own ring; the owner never shares that ring's write path (capture stays
// lock-free, one writer per ring) and only READS it, under the freeze the command itself applies.
//
// This lives here rather than in generated code because it is protocol: which cores a command
// selects, when a satellite window may be read, and what the host is owed in reply. loom2v wires
// the rings in and calls one function (docs/com-modules.md: the platform owns the protocol).

// on_cmd_multicore applies one TraceCmd frame across the owner's ring AND a satellite ring,
// importing the satellite's frozen window when the command dumps it.
//
// `remote_backing`/`remote_cap` are the caller-owned storage the imported window is staged in —
// the same contract as set_remote and new_buffer, so the module gains no per-satellite fields
// (it already lives in __global on target, where every added array is bss).
//
// Ordering matters, and is why this is one function rather than two calls:
//   1. the satellite is stopped and imported BEFORE the local dump is armed, so produce() finds
//      the remote block already queued and streams local-then-remote as one uninterrupted
//      sequence — the host reads one transfer per selected core, in core order;
//   2. arm/reset reach the satellite too, so "arm" means "both cores from now" rather than
//      "core 0 now, core 1 whenever it is next addressed" — the coherent window the multi-core
//      view exists to provide.
//
// Returns whether a satellite window was imported on this call.
pub fn (mut m TraceModule) on_cmd_multicore(f can.Frame, mut sat TraceBuffer, sat_core u8, remote_backing &Record, remote_cap u32) bool {
	if f.len < 8 {
		return false // short frame on the wire — never decode stale bytes
	}
	mut b := [8]u8{}
	for i in 0 .. 8 {
		b[i] = f.data[i]
	}
	c := decode_cmd(b)
	mut imported := false
	// The satellite half first. Its core mask is checked the same way handle_cmd checks the
	// owner's, so a command that does not select sat_core leaves the satellite untouched.
	if c.targets(sat_core) {
		match c.opcode {
			op_arm, op_start, op_reset {
				sat.start()
			}
			op_stop {
				sat.stop()
			}
			op_dump {
				// Only a stopped window is safe to read — a capturing ring is still being written
				// by the other core. Freeze it here rather than requiring a separate stop: a dump
				// that quietly returned a moving window would be the same class of lie as a trace
				// that never answers at all.
				if sat.state() == .capturing {
					sat.stop()
				}
				// used() == 0 emits NO block rather than one claiming an empty window: the host
				// must be able to tell "this core captured nothing" from "this core was never
				// asked", and a zero-record block reads as the latter.
				if (sat.state() == .full || sat.state() == .frozen) && sat.used() > 0 {
					m.set_remote(sat_core, remote_backing, remote_cap)
					m.load_remote_buffer(sat)
					imported = true
				}
			}
			else {} // status / set_push / unknown: the local half answers for the owner
		}
	}
	// The local half, unchanged: the owner's own ring, core id and response.
	m.on_cmd(f)
	return imported
}

// load_remote_buffer imports a frozen satellite ring that lives in THIS address space (the host
// multi-core case) — the sibling of load_remote, which takes the 8-byte wire form because its
// window arrived over a transport. Copying Record-to-Record skips an encode/decode round trip
// that could only lose information, and reads the source through its public accessors, so the
// producer's state is never touched.
fn (mut m TraceModule) load_remote_buffer(sat TraceBuffer) {
	m.remote.start()
	// The offset leads the block so it is in hand before the first record it applies to. Same
	// rule as load_remote: never measured means emit NOTHING, because a 0 offset would claim
	// perfect correlation. Two host partitions read one clock (osal.now_us), so a generated
	// caller leaves it unmeasured and the block simply carries no offset record.
	if m.remote_offset_known {
		m.remote.push(new_core_offset(m.remote_offset_us, m.remote_bound_us))
	}
	n := sat.used()
	for i in 0 .. n {
		m.remote.push(sat.record_at(i))
	}
	m.remote.stop()
	m.remote_due = true
	m.remote_from = 0
}
