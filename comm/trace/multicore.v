module trace

import driver.can

// Host multi-core trace (P3a, docs/trace-multicore.md §3): one dump owner, N producing cores.
//
// The owner is an ordinary app partition — it runs its own handlers, so its ring is genuinely
// LOCAL (m.buf) and the existing single-core path serves it unchanged. A second partition on
// another core writes its own ring. The owner READS that ring to import a frozen window, and
// writes only its STATE field, and only when the host explicitly says so (arm/stop/reset) — never
// on a dump. push() tests state first and self-quiesces, so a stop racing a push costs at most one
// torn record, which docs/trace-multicore.md §7 accepts for a diagnostic ring on the sim host. The
// ThreadX target freezes with real synchronisation; this is the host runner only.
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
//   1. the satellite is imported BEFORE the local dump is armed, so produce() finds the remote
//      block already queued and streams local-then-remote as one uninterrupted sequence — the
//      host reads one transfer per selected core, in core order;
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
	// A (re)arm consumes the system freeze — but only one that ADDRESSES a core this runner
	// generated: a mask naming neither core restarts nothing, and clearing for it would erase
	// a notification a tripped core had just raised for a peer that has not looked yet (codex
	// #271 r3). Retired BEFORE any ring restarts (a stale cell would re-freeze the ring the
	// host just armed) and AGAIN after them: a dispatch overlapping the restart can raise the
	// cell for the window being erased, and that raise would freeze the fresh windows on
	// their first record. The residual is symmetric and bounded to that same overlap: a
	// GENUINE overrun landing inside the restart microwindow has its raise retired too, and
	// is notified on its next over-budget dispatch instead (the record's flag_overran flies
	// either way). The satellite is not quiesced for commands — the same P3a simplification
	// as sat.start() itself, which restarts the peer's ring from this thread.
	rearms := (c.opcode == op_arm || c.opcode == op_start || c.opcode == op_reset)
		&& (c.targets(m.core) || c.targets(sat_core))
	if rearms {
		m.retire_freeze()
	}
	// A dump must not be accepted while ANY part of the previous one is still outstanding.
	// on_cmd's own busy check only covers the ISO-TP link, not a queued local_due/remote_due
	// block, so a dump arriving in the IDLE GAP between continuation transfers was accepted:
	// it reset local_from and re-sent the owner's blocks ahead of the satellite block still
	// queued behind them, corrupting the multi-core stream. Answer busy and delegate nothing.
	if c.opcode == op_dump && m.is_streaming() {
		if c.targets(m.core) {
			m.queue_rsp(status_rsp(m.buf, c.opcode, result_busy, m.core))
		} else if c.targets(sat_core) {
			m.queue_rsp(status_rsp(sat, c.opcode, result_busy, sat_core))
		}
		return false
	}
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
				// Mirror handle_cmd EXACTLY: only a stopped window may be read, and a request
				// against a capturing one is refused — it does NOT freeze it. The first version
				// froze here, which meant a dump the owner then rejected (not_ready, or busy)
				// still killed core 1's flight recorder and pushed out an unsolicited block. A
				// command that fails must leave both rings exactly as it found them.
				//
				// Nor may a fresh import land on top of a transfer already in flight: it would
				// reset the continuation cursor under the stream and re-send chunks the host had
				// already taken. The host's own retry path is to wait for the transfer to finish.
				if (sat.state() == .full || sat.state() == .frozen) && sat.used() > 0 {
					// used() == 0 emits NO block rather than one claiming an empty window: the
					// host must be able to tell "this core captured nothing" from "this core was
					// never asked", and a zero-record block reads as the latter.
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
	// A command addressed to the SATELLITE ONLY (e.g. core mask 0x0002) does not select the owner,
	// so handle_cmd reports it unaddressed and answers nothing at all — the host would see silence
	// and could not tell a busy target from a wrong id. Answer for the satellite in that case.
	// When the mask selects BOTH, the owner's response stands and the satellite's state reaches
	// the host in its own block header; queue_rsp refuses rather than overwrite it.
	if c.targets(sat_core) && !c.targets(m.core) {
		m.queue_rsp(status_rsp(sat, c.opcode, result_ok, sat_core))
	}
	if rearms {
		m.retire_freeze() // the second half of the bracket above — after every restart
	}
	return imported
}

// load_remote_buffer imports a frozen satellite ring that lives in THIS address space (the host
// multi-core case) — the sibling of load_remote, which takes the 8-byte wire form because its
// window arrived over a transport. Copying Record-to-Record skips an encode/decode round trip
// that could only lose information, and reads the source through its public accessors, so the
// producer's state is never touched.
fn (mut m TraceModule) load_remote_buffer(sat TraceBuffer) {
	m.remote.start()
	// Carry the source's epoch PREFIX. A ring that has wrapped past its oldest epoch keeps that
	// epoch's base in prefix_base, and pack_chunk anchors every block from it. Copying only the
	// records left the imported window anchored at 0, which shifts the satellite's whole lane by
	// however long it had been running — ~16.8 s once start_us has wrapped its u24 once.
	m.remote.has_prefix = sat.has_prefix
	m.remote.prefix_base = sat.prefix_base
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
