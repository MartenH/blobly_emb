module main

// e2e: build the example, run the binary, and listen on the configured peer
// endpoint (127.0.0.1:30491) — the io e2e pattern carried to the eth bus
// (proven-on-lo, docs/someip.md). Every datagram is decoded through the REAL
// rx envelope gate (comm/someip check_event) AND its payload decoded per the
// CONFIGURED derived layout (lengths, LE offsets, field relations — an
// endianness or offset regression fails here, not just pattern checks). Then
// each COM tx mode is asserted by the behavior that DISTINGUISHES it:
//   cyclic (0x8001): retransmits an UNCHANGED layout on cadence (the app
//     quantizes its payload to every 4th cycle so repeats must appear), with
//     the E2E trailer counter stepping loss-free;
//   event  (0x8002): the DEBOUNCE prover — the app steps the value every
//     100 ms against min_delay 350 ms, so the frame must coalesce: strictly
//     increasing levels, median pace at the configured delay, progressing
//     through the whole window;
//   mixed  (0x8003): heartbeats between changes (median repeat gap AT the
//     configured 300 ms, bounded both ways) AND publishes a change
//     immediately (a beat well inside the heartbeat interval).
// Timing uses dequeue timestamps, which a scheduler stall can compress —
// sub-20 ms gaps are treated as burst artifacts, and pacing claims use
// MEDIANS, so neither a stall nor an outlier flips a verdict.
// @verifies REQ-NET-013
import comm.someip
import net
import os
import time

const service = u16(0x0100)
const iface_ver = u8(1)
const id_cyclic = u16(0x8001)
const id_event = u16(0x8002)
const id_mixed = u16(0x8003)

struct Rx {
	at  time.Time
	pay []u8
}

fn le32(p []u8, o int) u32 {
	return u32(p[o]) | (u32(p[o + 1]) << 8) | (u32(p[o + 2]) << 16) | (u32(p[o + 3]) << 24)
}

fn le16(p []u8, o int) u16 {
	return u16(p[o]) | (u16(p[o + 1]) << 8)
}

// median inter-arrival gap in ms; burst artifacts (< 20 ms: queued datagrams
// dequeued back-to-back after a stall) are excluded
fn median_gap_ms(rs []Rx) i64 {
	mut gaps := []i64{}
	for i in 1 .. rs.len {
		g := (rs[i].at - rs[i - 1].at).milliseconds()
		if g >= 20 {
			gaps << g
		}
	}
	if gaps.len == 0 {
		return 0
	}
	gaps.sort()
	return gaps[gaps.len / 2]
}

fn test_tx_modes_on_the_wire() {
	dir := os.real_path(os.dir(@FILE))
	build := os.execute('make -C ${dir} V=${os.quoted_path(@VEXE)}')
	assert build.exit_code == 0, build.output

	// the peer endpoint from the example's [someip] config — bind BEFORE the
	// app starts so the first events land in our queue
	mut c := net.listen_udp('127.0.0.1:30491')!
	c.set_read_timeout(500 * time.millisecond)
	defer {
		c.close() or {}
	}
	mut p := os.new_process(os.join_path(dir, 'bin', 'app'))
	p.run()
	defer {
		p.signal_kill()
		p.wait()
	}

	// collect ~3.5 s of traffic (nominal: ~35 cyclic, ~7 event, ~11+5 mixed)
	mut by_id := map[u16][]Rx{}
	mut buf := []u8{len: 2048}
	start := time.now()
	for time.since(start) < 3500 * time.millisecond {
		n, _ := c.read(mut buf) or { continue }
		if n < someip.header_len {
			continue
		}
		h, ok := someip.decode(unsafe { &buf[0] }, n)
		assert ok
		// the REAL envelope gate accepts every datagram the image emits
		assert someip.check_event(h, n, service, iface_ver) == someip.Drop.none, 'dropped: ${h}'
		by_id[h.method] << Rx{
			at:  time.now()
			pay: buf[someip.header_len..n].clone()
		}
	}

	cyc := by_id[id_cyclic] or { []Rx{} }
	evs := by_id[id_event] or { []Rx{} }
	mixed := by_id[id_mixed] or { []Rx{} }

	// ---- cyclic: layout decode + time-driven resends AT THE CONFIGURED rate --
	// count band: 100 ms over ~3.5 s ≈ 35 — a 200 ms impostor lands ~17 and
	// fails the floor; an unthrottled one blows the cap
	assert cyc.len >= 24 && cyc.len <= 48, 'cyclic: ${cyc.len} datagrams (expected ~35 at 100 ms)'
	mut cyc_repeats := 0
	for i, r in cyc {
		// the CONFIGURED derived layout: load u8@0, ticks u32@1 LE, wraps
		// u16@5 LE, E2E trailer ctr@7/crc@8 — 9 bytes exactly
		assert r.pay.len == 9, 'cyclic payload ${r.pay.len} bytes'
		q := le32(r.pay, 1)
		// ticks/wraps are ONE signal (atomic snapshot); BenchLoad rides a
		// separate IOC channel and may legitimately pair with a NEIGHBOR q at
		// a transition — so its relation tolerates ±1 quantum, which still
		// fails a packer that drops or misplaces the byte (stuck 0 dies once
		// q passes 1)
		lo := r.pay[0]
		assert lo == u8(q % 100) || lo == u8((q + 1) % 100)
			|| (q > 0 && lo == u8((q - 1) % 100)), 'cyclic load ${lo} vs q ${q}'
		// wraps = q + 1000: nonzero in both bytes, so a codec that drops the
		// field or misplaces its offset/endianness fails on live values
		assert le16(r.pay, 5) == u16(q + 1000), 'cyclic field relation (wraps)'
		if i > 0 {
			// the app holds the layout for 4 cycles: cyclic MUST resend it
			// unchanged (the signal bytes repeat; only the trailer moves)
			if r.pay[..7] == cyc[i - 1].pay[..7] {
				cyc_repeats++
			}
			// and the E2E counter steps loss-free on lo
			assert (r.pay[7] & 0x0F) == ((cyc[i - 1].pay[7] & 0x0F) + 1) & 0x0F, 'cyclic E2E counter skipped'
		}
	}
	assert cyc_repeats >= 5, 'cyclic: only ${cyc_repeats} unchanged-layout resends — cadence is not time-driven'

	// ---- event: debounce + change-driven silence ----
	// the source alternates 1.2 s stepping / 1.2 s holding: coalesced sends
	// at the 350 ms debounce during stepping, SILENCE during holds
	assert evs.len >= 4 && evs.len <= 12, 'event: ${evs.len} datagrams (expected ~6 debounced)'
	assert evs.last().at - start > 2200 * time.millisecond, 'event publication stopped early'
	mut ev_hold_gap := false
	for i, r in evs {
		assert r.pay.len == 1, 'event payload ${r.pay.len} bytes'
		if i > 0 {
			// change-driven: strictly increasing — a cyclic impostor RESENDS
			// during the source's hold phases and fails right here
			assert r.pay[0] > evs[i - 1].pay[0], 'event level did not increase (${evs[i - 1].pay[0]} -> ${r.pay[0]})'
			if (r.at - evs[i - 1].at).milliseconds() >= 600 {
				ev_hold_gap = true
			}
		}
	}
	ev_pace := median_gap_ms(evs)
	assert ev_pace >= 300, 'event median pace ${ev_pace} ms — the configured 350 ms debounce is not active'
	assert ev_hold_gap, 'event: no silence over the source hold phase — sends are not change-driven'
	assert evs.last().pay[0] >= 12, 'event level ${evs.last().pay[0]} — publication did not track the source through the window'

	// ---- mixed: heartbeat repeats AND immediate-on-change ----
	assert mixed.len >= 8, 'mixed: only ${mixed.len} datagrams'
	mut repeats := 0
	mut repeat_gaps := []i64{}
	mut fast_change := false
	for i, r in mixed {
		assert r.pay.len == 2, 'mixed payload ${r.pay.len} bytes'
		if i > 0 {
			prev := mixed[i - 1]
			if le16(r.pay, 0) == le16(prev.pay, 0) {
				repeats++
				// same burst floor as median_gap_ms: stall-compressed dequeue
				// gaps must not drag the heartbeat median down
				g0 := (r.at - prev.at).milliseconds()
				if g0 >= 20 {
					repeat_gaps << g0
				}
			} else {
				// monotonic, usually +1 — but a stalled bridge legitimately
				// skips setpoints (IOC keeps only the latest), so no exact
				// step assert
				assert le16(r.pay, 0) > le16(prev.pay, 0), 'mixed setpoint went backwards'
				// an off-cycle change must be published BEFORE the next
				// heartbeat; the 20 ms floor rejects stall-compressed bursts
				g := (r.at - prev.at).milliseconds()
				if g >= 20 && g < 220 {
					fast_change = true
				}
			}
		}
	}
	assert repeats >= 2, 'mixed: no heartbeat repeats observed (${repeats})'
	// the heartbeat is paced AT the configured 300 ms — bounded BOTH ways
	// (median: robust to stall-compressed and stall-inflated outliers)
	repeat_gaps.sort()
	hb := repeat_gaps[repeat_gaps.len / 2]
	assert hb >= 240 && hb <= 480, 'mixed: heartbeat median gap ${hb} ms (configured 300)'
	assert fast_change, 'mixed: no change arrived inside the heartbeat interval — immediate-on-change is missing'
}
