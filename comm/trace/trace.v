module trace

// The captured trace buffer (docs/telemetry.md Part 2). A fixed, caller-backed per-core
// record buffer — no alloc: the owner supplies a fixed backing array (sized from config
// at build, `buffer_records`) and TraceBuffer only indexes it through a pointer. Single
// writer (the owning core's loop), so it never needs a lock. Two modes:
//   * one-shot — fill then stop ("trigger, let it fill, read it out").
//   * ring     — overwrite the oldest; on a trigger, keep `pre_pct` % of capacity from
//                before the trigger, capture the rest after, then freeze (flight recorder).

// Record is one interval in the trace ring (docs/telemetry.md "The record"): an entity ran
// `[start_us, start_us + cpu_us)`. `entity_id` merges the kind (top 2 bits) and a 14-bit id
// so an id is never a u8 — an ISR carries its raw vector, threads/fbs their manifest id,
// idle = THREAD id 0. `info` is the reason (THREAD) or flags (FB).
//
// Packed to a natural 8 bytes so a buffer is `[N]Record` with no padding (the RAM budget):
// `tsinfo` carries start_us in its low 24 bits and info in its top byte. The on-bus byte
// order is produced by encode_record (b0-1 entity_id, b2 info, b3-5 start_us, b6-7 cpu_us),
// so the in-RAM layout and the wire layout can't drift.
pub struct Record {
pub mut:
	entity_id u16 // kind:2 (bits 15-14) | id:14 (bits 13-0)
	cpu_us    u16
	tsinfo    u32 // bits 0-23 = start_us, bits 24-31 = info
}

// entity kinds — the top 2 bits of entity_id.
pub const kind_isr = u8(0) // id = raw interrupt vector
pub const kind_thread = u8(1) // id = thread_id (id 0 = idle / no thread)
pub const kind_fb = u8(2) // id = handler_id
pub const kind_control = u8(3) // id = a subtype (block-header, …)

// THREAD `info` — the OUTGOING thread's fate (why the core left it): the preemption signal.
pub const reason_preempt = u8(0) // still ready, will resume (a higher-priority thread/ISR-woken)
pub const reason_block = u8(1) // voluntarily blocked
pub const reason_yield = u8(2) // voluntarily yielded
pub const reason_exit = u8(3) // completed / terminated

// CONTROL `id` subtypes.
pub const ctl_block = u16(0) // per-core block header leading a multi-core dump
pub const ctl_epoch = u16(1) // timeline origin: resets the u24 start_us base (long captures)

// FB record flags (the `info` byte of a kind_fb record) — mirror comm.telem.trace_flag_* and
// blobly_net's telem.flag_*. flag_overran marks the invocation that exceeded its budget, i.e. the
// handler that tripped the ring trigger — the decoder highlights it so the culprit is visible.
pub const flag_overran = u8(0x01)
pub const flag_saturated = u8(0x04)

const id_mask = u16(0x3fff) // 14-bit id

// entity packs a kind + 14-bit id into an entity_id.
fn entity(kind u8, id u16) u16 {
	return (u16(kind) << 14) | (id & id_mask)
}

// pack_tsinfo folds a u24 start + a u8 info into the one u32 field.
fn pack_tsinfo(start_us u32, info u8) u32 {
	return (start_us & 0x00ff_ffff) | (u32(info) << 24)
}

// new_thread — a thread started running (id 0 = idle); `reason` is the outgoing thread's fate.
pub fn new_thread(id u16, reason u8, start_us u32, cpu_us u16) Record {
	return Record{
		entity_id: entity(kind_thread, id)
		cpu_us:    cpu_us
		tsinfo:    pack_tsinfo(start_us, reason)
	}
}

// new_idle — the core went idle (no thread ready); `reason` = why the last thread left.
pub fn new_idle(reason u8, start_us u32, cpu_us u16) Record {
	return new_thread(0, reason, start_us, cpu_us)
}

// new_isr — an interrupt ran; `vector` is the raw hardware vector (its 14-bit id).
pub fn new_isr(vector u16, start_us u32, cpu_us u16) Record {
	return Record{
		entity_id: entity(kind_isr, vector)
		cpu_us:    cpu_us
		tsinfo:    pack_tsinfo(start_us, 0)
	}
}

// new_fb — an fb.handler ran; `flags` = overran/first-run/saturated.
pub fn new_fb(id u16, flags u8, start_us u32, cpu_us u16) Record {
	return Record{
		entity_id: entity(kind_fb, id)
		cpu_us:    cpu_us
		tsinfo:    pack_tsinfo(start_us, flags)
	}
}

// new_block_header — the wire-only per-core header leading one core's block in a multi-core
// dump: names the core and how many records follow, so the stream splits by core with no
// external framing. CONTROL kind / ctl_block subtype; on the wire b2 = core, b3-6 = count (u32).
pub fn new_block_header(core u8, count u32) Record {
	return Record{
		entity_id: entity(kind_control, ctl_block)
		cpu_us:    u16((count >> 24) & 0xff)                 // b6 = count byte 3, b7 = 0
		tsinfo:    (count & 0x00ff_ffff) | (u32(core) << 24) // info(b2)=core, start(b3-5)=count low 24
	}
}

// new_epoch — a CONTROL record that resets the timeline origin. A Record's `start_us` is only
// 24 bits (~16.777 s at 1 µs), so a capture that stays armed longer would wrap and its records
// would sort near 0 ahead of older ones. The capture layer emits one epoch whenever the running
// `start_us` would exceed 0xff_ffff, carrying the full 32-bit `base_us` of the new origin; the
// decoder adds `base_us` to every following record's `start_us` until the next epoch. CONTROL
// kind / ctl_epoch subtype; the full u32 base lives in the tsinfo field (info=b31-24, start=b23-0).
pub fn new_epoch(base_us u32) Record {
	return Record{
		entity_id: entity(kind_control, ctl_epoch)
		tsinfo:    base_us // start_us()=low 24, info()=high 8 → reassembled = base_us
	}
}

// --- accessors ---
pub fn (r Record) kind() u8 {
	return u8(r.entity_id >> 14)
}

pub fn (r Record) id() u16 {
	return r.entity_id & id_mask
}

pub fn (r Record) info() u8 {
	return u8(r.tsinfo >> 24)
}

pub fn (r Record) start_us() u32 {
	return r.tsinfo & 0x00ff_ffff
}

// is_block_header reports the wire-only per-core dump header (CONTROL / ctl_block).
pub fn (r Record) is_block_header() bool {
	return r.kind() == kind_control && r.id() == ctl_block
}

// block-header accessors (valid when is_block_header()).
pub fn (r Record) header_core() u8 {
	return r.info()
}

pub fn (r Record) header_count() u32 {
	return r.start_us() | (u32(r.cpu_us) << 24)
}

// is_epoch reports a timeline-origin reset (CONTROL / ctl_epoch); epoch_base is its new base.
pub fn (r Record) is_epoch() bool {
	return r.kind() == kind_control && r.id() == ctl_epoch
}

pub fn (r Record) epoch_base() u32 {
	return r.start_us() | (u32(r.info()) << 24)
}

// encode_record packs a Record into its 8-byte wire form (little-endian):
// b0-1 entity_id | b2 info | b3-5 start_us | b6-7 cpu_us.
pub fn encode_record(r Record) [8]u8 {
	mut b := [8]u8{}
	b[0] = u8(r.entity_id)
	b[1] = u8(r.entity_id >> 8)
	b[2] = u8(r.tsinfo >> 24) // info
	b[3] = u8(r.tsinfo) // start_us byte 0
	b[4] = u8(r.tsinfo >> 8) // start_us byte 1
	b[5] = u8(r.tsinfo >> 16) // start_us byte 2
	b[6] = u8(r.cpu_us)
	b[7] = u8(r.cpu_us >> 8)
	return b
}

// decode_record is the inverse (tests / host tooling).
pub fn decode_record(b [8]u8) Record {
	return Record{
		entity_id: u16(b[0]) | (u16(b[1]) << 8)
		cpu_us:    u16(b[6]) | (u16(b[7]) << 8)
		tsinfo:    (u32(b[3]) | (u32(b[4]) << 8) | (u32(b[5]) << 16)) | (u32(b[2]) << 24)
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
	pre_pct  u8 // ring: % of capacity kept from before the trigger (0..100)
	state    State = .idle
	head     u32  // next write slot
	used     u32  // valid records (0..capacity)
	post_rem u32  // ring: records still to capture after a trigger
	pending  bool // ring: a trigger is armed
	// ring: an epoch record is an ordinary ring entry, so it can age out while records that
	// still reference its base survive. When the oldest evicted record is an epoch we remember
	// its base here (the base of every surviving record older than the first in-buffer epoch)
	// and prepend it on dump, so a wrapped window is never decoded against a lost base.
	prefix_base u32
	has_prefix  bool
	froze       u8 // why capture stopped: freeze_none/_stop/_trigger — reported in the TraceRsp
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
	t.prefix_base = 0
	t.has_prefix = false
	t.froze = freeze_none
}

// froze_cause reports why capture stopped (freeze_none while still capturing, freeze_stop for an
// explicit stop, freeze_trigger for the overrun trigger) — surfaced in the TraceRsp so a host can
// tell a trigger-frozen dump from a manually-stopped one.
pub fn (t TraceBuffer) froze_cause() u8 {
	return t.froze
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
				if t.froze == freeze_none { // completed on its own — report a cause, not freeze_none
					t.froze = freeze_stop
				}
			}
		}
		.ring {
			// full ring: t.head is the oldest slot, about to be evicted. If it's an epoch,
			// remember its base — the surviving records after it still decode against it.
			if t.used == t.cap {
				old := unsafe { t.buf[t.head] }
				if old.is_epoch() {
					t.prefix_base = old.epoch_base()
					t.has_prefix = true
				}
			}
			unsafe {
				t.buf[t.head] = r
			}
			t.head = (t.head + 1) % t.cap
			if t.used < t.cap {
				t.used++
			}
			// Once a full ring's oldest record is itself an epoch, an in-buffer epoch anchors
			// everything and the carried prefix is stale — drop it so it stops stealing a slot.
			if t.has_prefix && t.used == t.cap {
				oldest := unsafe { t.buf[t.head] } // full: head is the oldest slot
				if oldest.is_epoch() {
					t.has_prefix = false
				}
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
		if t.froze == freeze_none { // an armed trigger already recorded its cause; don't override it
			t.froze = freeze_stop
		}
	}
}

// trigger freezes the capture. Ring: keep pre_pct % from before the trigger, capture the
// remaining capacity after, then freeze. One-shot: stop now at the current fill.
pub fn (mut t TraceBuffer) trigger() {
	if t.state != .capturing {
		return
	}
	t.froze = freeze_trigger // the trigger is the freeze cause, even while the post-window fills
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
	mut i0 := u32(0)
	// If an epoch aged out of the ring, lead the dump with it so the oldest records keep their
	// base — but have it REPLACE the oldest slot (record_at(0), always a data record once a
	// newer epoch would have cleared has_prefix) rather than add a record. The dump then stays
	// exactly `used` records (matching TraceRsp.records_used) and every in-buffer epoch that
	// re-anchors later records is retained.
	if t.has_prefix && t.used > 0 {
		if out_cap < 8 {
			return 0
		}
		p := encode_record(new_epoch(t.prefix_base))
		unsafe {
			for j in 0 .. 8 {
				out[n + j] = p[j]
			}
		}
		n += 8
		i0 = 1
	}
	for i in i0 .. t.used {
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

// pack_block writes one core's dump block — a leading block-header record (core + the count
// of records that follow) then the encoded records — into `out`, up to `out_cap` bytes, and
// returns the byte count. Self-describing, so a multi-core dump stream splits by core with
// no external framing. The header count reflects records actually written, so a block
// truncated by `out_cap` stays internally consistent.
pub fn (t TraceBuffer) pack_block(out &u8, out_cap int, core u8) int {
	if out_cap < 8 {
		return 0
	}
	mut n := 8 // reserve the header slot; backfill it once the count is known
	mut count := u32(0)
	mut i0 := u32(0)
	// A preserved epoch (aged out of the ring) replaces the oldest slot (like pack()), so the
	// block stays `used` records — the header count and TraceRsp.records_used agree — and every
	// in-buffer epoch is retained.
	if t.has_prefix && t.used > 0 && n + 8 <= out_cap {
		p := encode_record(new_epoch(t.prefix_base))
		unsafe {
			for j in 0 .. 8 {
				out[n + j] = p[j]
			}
		}
		n += 8
		count++
		i0 = 1
	}
	for i in i0 .. t.used {
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
		count++
	}
	hdr := encode_record(new_block_header(core, count))
	unsafe {
		for j in 0 .. 8 {
			out[j] = hdr[j]
		}
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
