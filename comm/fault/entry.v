module fault

// Snapshots (freeze frames), extended data and displacement (docs/diagnostics.md §3.3, R6b).
//
// A DTC that declares `freeze` DIDs gets a SNAPSHOT at the occurrence that finds it without one.
// What it holds is DEFINED as the declared DIDs' values AT STORAGE — read from the diagnostic
// server's own DID table, the values 0x22 returns, in the owner pass that consumes the qualifying
// report (capture, called in that same pass) — as AUTOSAR's Dem captures a freeze frame when it
// processes the event, not at detection. So it describes the conditions at most one owner-pass
// interval after the report was published (on a ThreadX target the comm loop's wait: 10 ticks,
// 10 ms at tick_ms = 1, plus the pass itself), not the qualifying dispatch: a producer that
// dispatches several times meanwhile has moved its outputs on. The values are not carried in the
// report — a snapshot is far larger than the 64-byte report cell. One snapshot per DTC
// (ISO 14229-1 snapshot record 0x01), kept until the DTC is cleared, ages out, heals before
// confirming, or is displaced; a later occurrence does not overwrite it — the first failure is the
// evidence a workshop wants.
//
// Snapshots live in ENTRIES, `cap` of them, fewer than the DTCs when the configuration says so.
// The status byte and the counters of EVERY DTC are kept whatever happens to its entry: an entry
// holds only the snapshot, the one large thing. When every entry is taken, a new snapshot
// DISPLACES one (victim, below) or is not stored.
//
// Extended data (0x19 06) is the DTC's counters, records with fixed numbers and widths that the
// tester decodes without a description file:
//   0x01 occurrence counter    2 bytes, big-endian, saturating at 0xFFFF
//   0x02 aging counter         1 byte (passing cycles counted toward aging out)
//   0x03 failed-cycle counter  1 byte, saturating at 0xFF (failed cycles toward confirmation)

import comm.uds

pub const max_entries = 8 // snapshot entries one memory holds
pub const max_freeze = 4 // DIDs one snapshot names
// the snapshot record body (0x19 04, after the record number): the DID count, then each DID's
// identifier and data
pub const max_snapshot = 1 + max_freeze * (2 + uds.max_did_data)
pub const snapshot_record = u8(0x01) // the one snapshot record number
pub const ext_records = u8(3) // extended data records 0x01 .. 0x03

// Entry is one snapshot entry: the DTC (slot) holding it, its allocation stamp, and the record body.
pub struct Entry {
pub mut:
	used    bool
	slot    int
	stamp   u32
	durable bool // written to the store since it was captured
	blk     u8   // the slot's block it lives in: 1 A, 2 B — a capture's is never the one the committed
	// image claims; a restored one is the claimed block it was read from
	// it displaced a snapshot the durable image claims: no image may be written until this one is
	// durable, or a power cut would leave neither (persist.v)
	took_claim bool
	len     int
	data    [max_snapshot]u8
}

// snap_len: the body length slot i's snapshot has — fixed by its configuration.
pub fn (m &Memory) snap_len(i int) int {
	return m.slots[i].body_len()
}

// body_len: the record body length this slot's snapshot has: the DID count, each DID's id and data.
pub fn (s &Slot) body_len() int {
	mut n := 1
	for k in 0 .. s.nfreeze {
		n += 2 + int(s.freeze_len[k])
	}
	return n
}

// capture_due: an occurrence is waiting for its snapshot — the owner refreshes the live DIDs and
// calls capture.
pub fn (m &Memory) capture_due() bool {
	for i in 0 .. m.n {
		if m.slots[i].snap_due {
			return true
		}
	}
	return false
}

// capture takes every due snapshot from the server's DID table (refreshed by the owner just
// before), in the owner pass that consumed the occurrence — the snapshot is the values AT STORAGE,
// at most one owner-pass interval after the report (see the module doc for the bound): each declared DID's current bytes, zero-filled to its declared size when the server
// holds fewer (a live DID nothing has published yet), so the record always has its fixed shape.
pub fn (mut m Memory) capture(srv &uds.Server) {
	for i in 0 .. m.n {
		if !m.slots[i].snap_due {
			continue
		}
		m.slots[i].snap_due = false
		// none for a DTC whose failure is no longer stored by the time the owner gets here (a cycle
		// end that healed it, or a clear, in the same pass): its snapshot would describe nothing
		if m.slots[i].nfreeze == 0 || m.slots[i].entry != 0
			|| m.slots[i].status & (pending | confirmed) == 0 {
			continue
		}
		k := m.allocate(i)
		if k < 0 {
			continue // full, and nothing may be displaced for it
		}
		mut e := &m.entries[k]
		e.data[0] = u8(m.slots[i].nfreeze)
		mut o := 1
		for f in 0 .. m.slots[i].nfreeze {
			id := m.slots[i].freeze[f]
			w := int(m.slots[i].freeze_len[f])
			e.data[o] = u8(id >> 8)
			e.data[o + 1] = u8(id)
			o += 2
			mut d := -1
			for j in 0 .. srv.ndid {
				if srv.dids[j].id == id {
					d = j
					break
				}
			}
			for b in 0 .. w {
				e.data[o + b] = if d >= 0 && b < int(srv.dids[d].len) { srv.dids[d].data[b] } else { u8(0) }
			}
			o += w
		}
		e.len = o
	}
}

// allocate gives slot i an entry: a free one, else the victim's. -1 = none may be taken.
fn (mut m Memory) allocate(i int) int {
	mut took := false
	mut k := -1
	for j in 0 .. m.cap {
		if !m.entries[j].used {
			k = j
			break
		}
	}
	if k < 0 {
		k = m.victim(i)
		if k < 0 {
			return -1
		}
		v := m.entries[k].slot
		m.slots[v].entry = 0 // displaced: its snapshot goes, its status and counters stay
		m.displaced++
		// the victim holds a committed claim on a snapshot that is really there (or its entry
		// itself took such a claim): until the new snapshot is written, no image may drop it
		took = (m.slots[v].claim != 0 && m.slots[v].claim_ok) || m.entries[k].took_claim
	}
	m.entries[k].took_claim = took
	m.entries[k].used = true
	m.entries[k].slot = i
	m.entries[k].stamp = m.next_stamp
	m.entries[k].durable = false
	m.entries[k].len = 0
	// the block the committed image does NOT claim: a snapshot it still claims is never overwritten
	m.entries[k].blk = if m.slots[i].claim == 1 { u8(2) } else { u8(1) }
	m.next_stamp++
	m.slots[i].entry = k + 1
	return k
}

// victim: the entry a new snapshot for slot i may displace, -1 = none. Never one whose DTC failed
// in THIS operation cycle (it is the evidence of now — and two DTCs failing alternately could
// otherwise displace each other at every occurrence), never an active confirmed one (testFailed
// and confirmedDTC: the fault a workshop is there for), and never a MORE important one (a lower
// priority number). Among the rest: the least important first, then one not currently failed,
// then the oldest.
fn (m &Memory) victim(i int) int {
	want := prio(m.slots[i].priority)
	mut best := -1
	for j in 0 .. m.cap {
		if !m.entries[j].used {
			continue
		}
		st := m.slots[m.entries[j].slot].status
		if st & test_failed_this_cycle != 0 || st & (test_failed | confirmed) == test_failed | confirmed {
			continue
		}
		if prio(m.slots[m.entries[j].slot].priority) < want {
			continue
		}
		if best < 0 || m.displaces_before(j, best) {
			best = j
		}
	}
	return best
}

// displaces_before: entry a goes before entry b — less important, then passive, then older.
fn (m &Memory) displaces_before(a int, b int) bool {
	sa := &m.slots[m.entries[a].slot]
	sb := &m.slots[m.entries[b].slot]
	pa := prio(sa.priority)
	pb := prio(sb.priority)
	if pa != pb {
		return pa > pb
	}
	fa := sa.status & test_failed != 0
	fb := sb.status & test_failed != 0
	if fa != fb {
		return !fa
	}
	return m.entries[a].stamp < m.entries[b].stamp
}

fn prio(p u8) int {
	return if p == 0 { 255 } else { int(p) }
}

// free_entry drops slot i's snapshot entry (clear, aging, healing).
fn (mut m Memory) free_entry(i int) {
	k := m.slots[i].entry - 1
	if k >= 0 {
		m.entries[k].used = false
		m.entries[k].durable = false
	}
	m.slots[i].entry = 0
}

// snapshot_of copies slot i's snapshot record body into out (nil = only ask) and returns its
// length; 0 = none stored.
pub fn (m &Memory) snapshot_of(i int, out &u8, cap int) int {
	if i < 0 || i >= m.n || m.slots[i].entry == 0 {
		return 0
	}
	e := &m.entries[m.slots[i].entry - 1]
	if out == unsafe { nil } {
		return e.len
	}
	if e.len > cap {
		return -1
	}
	for b in 0 .. e.len {
		unsafe {
			out[b] = e.data[b]
		}
	}
	return e.len
}

// extended_of writes slot i's extended data record `rec` into out (at most `cap` bytes) and returns
// its length; 0 = no such record (0x01 .. ext_records), -1 = it does not fit.
pub fn (m &Memory) extended_of(i int, rec u8, out &u8, cap int) int {
	if i < 0 || i >= m.n {
		return 0
	}
	need := match rec {
		0x01 { 2 }
		0x02, 0x03 { 1 }
		else { 0 }
	}
	if need > cap {
		return -1
	}
	s := &m.slots[i]
	match rec {
		0x01 {
			unsafe {
				out[0] = u8(s.occurrence >> 8)
				out[1] = u8(s.occurrence)
			}
			return 2
		}
		0x02 {
			unsafe {
				out[0] = s.aging_count
			}
			return 1
		}
		0x03 {
			unsafe {
				out[0] = s.failed_cycles
			}
			return 1
		}
		else {
			return 0
		}
	}
}

fn ops_snapshot(ctx voidptr, i int, out &u8, cap int) int {
	m := unsafe { &Memory(ctx) }
	return m.snapshot_of(i, out, cap)
}

fn ops_extended(ctx voidptr, i int, rec u8, out &u8, cap int) int {
	m := unsafe { &Memory(ctx) }
	return m.extended_of(i, rec, out, cap)
}
