module trace

// The captured trace buffer (docs/telemetry.md Part 2). A fixed, caller-backed per-core
// record buffer — no alloc: the owner supplies a fixed backing array (sized from config
// at build, `buffer_records`) and TraceBuffer only indexes it through a pointer. Single
// writer (the owning core's loop), so it never needs a lock. Two modes:
//   * one-shot — fill then stop ("trigger, let it fill, read it out").
//   * ring     — overwrite the oldest; on a trigger, keep `pre_pct` % of capacity from
//                before the trigger, capture the rest after, then freeze (flight recorder).

// Record is one handler invocation. Fields are ordered largest-first so the struct is a
// natural 8 bytes (u32 + u16 + u8 + u8, no padding) — matching the RAM budget. The on-bus
// byte order is separate (handler_id, flags, start_us, cpu_us) and produced by
// encode_record, so the in-RAM layout and the wire layout can't drift.
pub struct Record {
pub mut:
	start_us   u32 // µs relative to capture start
	cpu_us     u16
	handler_id u8
	flags      u8
}

// encode_record packs a Record into its 8-byte wire form (little-endian):
// b0 handler_id | b1 flags | b2-5 start_us | b6-7 cpu_us.
pub fn encode_record(r Record) [8]u8 {
	mut b := [8]u8{}
	b[0] = r.handler_id
	b[1] = r.flags
	b[2] = u8(r.start_us)
	b[3] = u8(r.start_us >> 8)
	b[4] = u8(r.start_us >> 16)
	b[5] = u8(r.start_us >> 24)
	b[6] = u8(r.cpu_us)
	b[7] = u8(r.cpu_us >> 8)
	return b
}

// decode_record is the inverse (tests / host tooling).
pub fn decode_record(b [8]u8) Record {
	return Record{
		start_us:   u32(b[2]) | (u32(b[3]) << 8) | (u32(b[4]) << 16) | (u32(b[5]) << 24)
		cpu_us:     u16(b[6]) | (u16(b[7]) << 8)
		handler_id: b[0]
		flags:      b[1]
	}
}

pub enum Mode {
	oneshot
	ring
}

pub enum State {
	idle      // not capturing
	capturing // recording
	full      // one-shot buffer filled, stopped
	frozen    // ring frozen by a trigger, stopped
}

pub struct TraceBuffer {
mut:
	buf      &Record = unsafe { nil } // caller-owned fixed backing of `cap` records
	cap      u32
	mode     Mode
	pre_pct  u8    // ring: % of capacity kept from before the trigger (0..100)
	state    State = .idle
	head     u32  // next write slot
	used     u32  // valid records (0..capacity)
	post_rem u32  // ring: records still to capture after a trigger
	pending  bool // ring: a trigger is armed
}

// new_buffer wraps a caller-owned fixed backing array of `capacity` records (no alloc:
// the backing is a static array the caller declares, e.g. from `buffer_records`).
pub fn new_buffer(backing &Record, capacity u32, mode Mode, pre_pct u8) TraceBuffer {
	mut p := pre_pct
	if p > 100 {
		p = 100
	}
	// The caller owns `backing` and must keep it alive for the buffer's lifetime; taking
	// the pointer here is that contract (V otherwise refuses a possibly-stack reference).
	return unsafe {
		TraceBuffer{
			buf:     backing
			cap:     capacity
			mode:    mode
			pre_pct: p
		}
	}
}

// start (re)arms capture from empty.
pub fn (mut t TraceBuffer) start() {
	t.state = .capturing
	t.head = 0
	t.used = 0
	t.post_rem = 0
	t.pending = false
}

pub fn (t TraceBuffer) capacity() u32 {
	return t.cap
}

pub fn (t TraceBuffer) used() u32 {
	return t.used
}

pub fn (t TraceBuffer) state() State {
	return t.state
}

// push records one invocation if capturing (a no-op otherwise, so pushes after a stop
// can't corrupt a frozen buffer).
pub fn (mut t TraceBuffer) push(r Record) {
	if t.state != .capturing || t.cap == 0 {
		return
	}
	match t.mode {
		.oneshot {
			unsafe {
				t.buf[t.used] = r
			}
			t.used++
			if t.used >= t.cap {
				t.state = .full
			}
		}
		.ring {
			unsafe {
				t.buf[t.head] = r
			}
			t.head = (t.head + 1) % t.cap
			if t.used < t.cap {
				t.used++
			}
			if t.pending {
				if t.post_rem > 0 {
					t.post_rem--
				}
				if t.post_rem == 0 {
					t.state = .frozen
				}
			}
		}
	}
}

// stop freezes capture immediately at the current fill, in any mode — distinct from a
// pre/post trigger. A ring goes to `frozen`, a one-shot to `full`.
pub fn (mut t TraceBuffer) stop() {
	if t.state == .capturing {
		t.state = if t.mode == .ring { State.frozen } else { State.full }
		t.pending = false
		t.post_rem = 0
	}
}

// trigger freezes the capture. Ring: keep pre_pct % from before the trigger, capture the
// remaining capacity after, then freeze. One-shot: stop now at the current fill.
pub fn (mut t TraceBuffer) trigger() {
	if t.state != .capturing {
		return
	}
	match t.mode {
		.oneshot {
			t.state = .full
		}
		.ring {
			if t.pending {
				return
			}
			post := t.cap - (t.cap * u32(t.pre_pct) / 100)
			t.pending = true
			t.post_rem = post
			if post == 0 {
				t.state = .frozen
			}
		}
	}
}

// pack writes the captured records, encoded (8 bytes each) and in chronological order,
// into `out` — up to `out_cap` bytes — and returns the byte count. This is the payload
// for an ISO-TP dump; `out` is a caller-owned fixed buffer (no alloc).
pub fn (t TraceBuffer) pack(out &u8, out_cap int) int {
	mut n := 0
	for i in u32(0) .. t.used {
		if n + 8 > out_cap {
			break
		}
		b := encode_record(t.record_at(i))
		unsafe {
			for j in 0 .. 8 {
				out[n + j] = b[j]
			}
		}
		n += 8
	}
	return n
}

// record_at returns the i-th record in chronological (oldest-first) order — the read-out
// order for a dump. For a wrapped ring the oldest sits at `head`.
pub fn (t TraceBuffer) record_at(i u32) Record {
	if i >= t.used || t.cap == 0 {
		return Record{}
	}
	start := if t.used == t.cap { t.head } else { u32(0) }
	idx := (start + i) % t.cap
	return unsafe { t.buf[idx] }
}
