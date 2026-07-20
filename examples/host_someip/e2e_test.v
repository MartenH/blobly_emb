module main

// e2e: build the example, run the binary, and listen on the configured peer
// endpoint (127.0.0.1:30491) — the io e2e pattern carried to the eth bus
// (proven-on-lo, docs/someip.md). Every datagram is decoded through the REAL
// rx envelope gate (comm/someip check_event) AND its payload decoded per the
// CONFIGURED derived layout (lengths, LE offsets, field relations — an
// endianness or offset regression fails here, not just pattern checks). Then
// each COM tx mode is asserted by the behavior that DISTINGUISHES it:
//   cyclic (0x8001): retransmits on PURE cadence — the 400 ms payload steps
//     land mid-cycle (300 ms), so a change-driven impostor shows an
//     off-cadence gap that every-gap-at-cadence rejects; unchanged-layout
//     resends must appear, and the E2E trailer counter steps loss-free;
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
import comm.e2e
import comm.someip
import net
import os
import time

const service = u16(0x0100)
const iface_ver = u8(1)
const id_cyclic = u16(0x8001)
const id_event = u16(0x8002)
const id_mixed = u16(0x8003)
const id_echo = u16(0x8004)
const id_cmd = u16(0x8010)
const id_cmd_safe = u16(0x8011)

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

	// ---- cyclic: layout decode + PURE cadence across the whole window ----
	// 300 ms over ~3.5 s ≈ 11; the app's payload steps every 400 ms land
	// MID-cycle, so a mixed impostor's immediate change-send would create an
	// off-cadence gap — every (non-burst) gap must sit AT the cadence
	assert cyc.len >= 8 && cyc.len <= 16, 'cyclic: ${cyc.len} datagrams (expected ~11 at 300 ms)'
	assert cyc.last().at - start > 3000 * time.millisecond, 'cyclic transmission stopped early'
	for i in 1 .. cyc.len {
		g := (cyc[i].at - cyc[i - 1].at).milliseconds()
		if g >= 20 {
			assert g >= 240, 'cyclic gap ${g} ms — an off-cadence (change-driven) send'
		}
	}
	mut cyc_repeats := 0
	for i, r in cyc {
		// the FIRST frame can legitimately ship before BenchTicks' first IOC
		// publication (separate channels, either-acquired sends) — its field
		// relations are undefined; everything from frame 1 on is strict
		if i == 0 && le32(r.pay, 1) == 0 {
			continue
		}
		// the CONFIGURED derived layout: load u8@0, ticks u32@1 LE, wraps
		// u16@5 LE, E2E trailer ctr@7/crc@8 — 9 bytes exactly
		assert r.pay.len == 9, 'cyclic payload ${r.pay.len} bytes'
		q := le32(r.pay, 1) - 0x01020304 // the all-bytes-live base
		// ticks/wraps are ONE signal (atomic snapshot); BenchLoad rides a
		// separate IOC channel and may legitimately pair with a NEIGHBOR q at
		// a transition — so its relation tolerates ±1 quantum, which still
		// fails a packer that drops or misplaces the byte (stuck 0 dies once
		// q passes 1)
		lo := r.pay[0]
		assert lo == u8(q % 100) || lo == u8((q + 1) % 100) || (q > 0 && lo == u8((q - 1) % 100)), 'cyclic load ${lo} vs q ${q}'
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
	assert cyc_repeats >= 2, 'cyclic: only ${cyc_repeats} unchanged-layout resends — cadence is not time-driven'
	cyc_pace := median_gap_ms(cyc)
	assert cyc_pace >= 240 && cyc_pace <= 400, 'cyclic median pace ${cyc_pace} ms (configured 300)'

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
	assert ev_pace >= 300 && ev_pace <= 700, 'event median pace ${ev_pace} ms (configured 350 ms debounce)'

	assert ev_hold_gap, 'event: no silence over the source hold phase — sends are not change-driven'
	assert evs.last().pay[0] >= 12, 'event level ${evs.last().pay[0]} — publication did not track the source through the window'

	// ---- mixed: heartbeat repeats AND immediate-on-change ----
	// count band: ~11 heartbeats + ~5 changes; a duplicate-burst sender blows
	// the cap even though its sub-20 ms gaps dodge the pacing stats
	assert mixed.len >= 8 && mixed.len <= 26, 'mixed: ${mixed.len} datagrams'

	mut repeats := 0
	mut repeat_gaps := []i64{}
	mut last_repeat_at := start
	mut fast_changes := 0
	mut last_fast_at := start
	for i, r in mixed {
		assert r.pay.len == 2, 'mixed payload ${r.pay.len} bytes'
		if i > 0 {
			prev := mixed[i - 1]
			if le16(r.pay, 0) == le16(prev.pay, 0) {
				repeats++
				last_repeat_at = r.at
				// same burst floor as median_gap_ms: stall-compressed dequeue
				// gaps must not drag the heartbeat median down
				g0 := (r.at - prev.at).milliseconds()
				if g0 >= 20 {
					repeat_gaps << g0
				}
			} else {
				// monotonic, usually +1 — but a stalled bridge legitimately
				// skips setpoints (IOC keeps only the latest), so no exact
				// step assert. Values sit at 1000+n: BOTH bytes are live, so
				// a byte-swapped packer decodes wildly out of range
				assert le16(r.pay, 0) > le16(prev.pay, 0), 'mixed setpoint went backwards'
				assert le16(r.pay, 0) >= 1000 && le16(r.pay, 0) < 1100, 'mixed setpoint ${le16(r.pay,
					0)} out of range — layout/endianness'
				// an off-cycle change must be published BEFORE the next
				// heartbeat; the 20 ms floor rejects stall-compressed bursts
				g := (r.at - prev.at).milliseconds()
				if g >= 20 && g < 220 {
					fast_changes++
					last_fast_at = r.at
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
	// and the heartbeat PERSISTS — a sender that stops repeating after a good
	// start (keeping only change-driven sends) fails this window bound
	assert last_repeat_at - start > 3000 * time.millisecond, 'mixed: heartbeats stopped early'

	// immediate-on-change works REPEATEDLY and into the window's second half —
	// a sender that degrades to cyclic-only after one good change fails
	assert fast_changes >= 2, 'mixed: only ${fast_changes} immediate change-sends'
	assert last_fast_at - start > 1800 * time.millisecond, 'mixed: immediate change-sends stopped early'
}

// cmd_datagram builds a BenchCmd notification carrying one level byte —
// through the REAL tx codec, so the probe cannot drift from the wire format.
fn cmd_datagram(level u8) []u8 {
	h := someip.notification(service, id_cmd, iface_ver, 1)
	mut d := []u8{len: someip.header_len + 1}
	someip.encode(h, unsafe { &d[0] })
	d[someip.header_len] = level
	return d
}

// drain_echoes collects every BenchEcho level arriving on the peer socket
// within the window (the app's other event frames stream interleaved and are
// skipped by id).
fn drain_echoes(mut c net.UdpConn, window time.Duration) []u8 {
	mut out := []u8{}
	mut buf := []u8{len: 2048}
	start := time.now()
	for time.since(start) < window {
		n, _ := c.read(mut buf) or { continue }
		if n < someip.header_len {
			continue
		}
		h, ok := someip.decode(unsafe { &buf[0] }, n)
		if !ok || h.method != id_echo {
			continue
		}
		assert n - someip.header_len == 1, 'echo payload ${n - someip.header_len} bytes'
		out << buf[someip.header_len]
	}
	return out
}

// rx direction: the app's comm thread must accept exactly the datagrams the
// design admits — the configured peer endpoint (source filter, REQ-NET-017),
// a valid notification envelope (gate, REQ-NET-015), a routed event id with
// the exact payload length — and prove acceptance end to end by the app
// echoing the received level back on the wire. Every refusal is a silent
// counted drop: the app must keep serving good frames through a malformed
// flood, never faulting.
// @verifies REQ-NET-015 REQ-NET-017
fn test_rx_gate_filter_router() {
	dir := os.real_path(os.dir(@FILE))
	build := os.execute('make -C ${dir} V=${os.quoted_path(@VEXE)}')
	assert build.exit_code == 0, build.output

	// the configured peer endpoint — the ONE legal talker
	mut c := net.listen_udp('127.0.0.1:30491')!
	c.set_read_timeout(100 * time.millisecond)
	defer {
		c.close() or {}
	}
	// a rogue source: same host, different port — must be filtered
	mut rogue := net.listen_udp('127.0.0.1:30492')!
	defer {
		rogue.close() or {}
	}
	app_addr := net.resolve_addrs('127.0.0.1:30490', .ip, .udp)![0]
	mut p := os.new_process(os.join_path(dir, 'bin', 'app'))
	// capture stderr: the rate-limited drop notice is the counter's observable
	// face — REQ-NET-015/017 require refusals COUNTED, not just not-echoed
	p.set_redirect_stdio()
	p.run()
	defer {
		p.signal_kill()
		p.wait()
	}
	time.sleep(500 * time.millisecond) // let the comm thread bind + settle

	// ---- round-trip: a good frame from the good source echoes back ----
	c.write_to(app_addr, cmd_datagram(42))!
	mut echoes := drain_echoes(mut c, 2000 * time.millisecond)
	assert 42 in echoes, 'no echo of level 42 — the rx chain (filter/gate/route/unpack/publish) is broken'

	// ---- source filter: the same valid frame from a rogue port is dropped ----
	rogue.write_to(app_addr, cmd_datagram(77))!
	echoes = drain_echoes(mut c, 1000 * time.millisecond)
	assert 77 !in echoes, 'level 77 echoed — a non-peer source got through the filter (REQ-NET-017)'

	// ---- envelope gate + router: a malformed flood, then a good frame ----
	// each refused for a different reason; the app must neither fault nor
	// wedge, and must still serve the good frame that follows
	c.write_to(app_addr, [u8(1), 2, 3])! // short: no header
	c.write_to(app_addr, []u8{len: 1, init: 0}[..0])! // zero-length: a REAL datagram, counted not idle
	mut d := cmd_datagram(9)
	d[12] = 2 // wrong protocol version
	c.write_to(app_addr, d)!
	d = cmd_datagram(9)
	d[0] = 0x99 // foreign service id
	c.write_to(app_addr, d)!
	d = cmd_datagram(9)
	d[13] = 9 // interface version mismatch
	c.write_to(app_addr, d)!
	d = cmd_datagram(9)
	d[2] &= 0x7F // event bit cleared: not an event id
	c.write_to(app_addr, d)!
	d = cmd_datagram(9)
	d[7] = 0x30 // Length inconsistent with the datagram
	c.write_to(app_addr, d)!
	d = cmd_datagram(9)
	d << u8(0)
	d << u8(0)
	d[7] += 2 // consistent envelope, wrong payload length for the route
	c.write_to(app_addr, d)!
	h := someip.notification(service, u16(0x8099), iface_ver, 1) // unrouted id
	d = []u8{len: someip.header_len + 1}
	someip.encode(h, unsafe { &d[0] })
	c.write_to(app_addr, d)!
	c.write_to(app_addr, cmd_datagram(55))! // and the good one after the storm
	echoes = drain_echoes(mut c, 2000 * time.millisecond)
	assert 9 !in echoes, 'a malformed frame was decoded and echoed (REQ-NET-015)'
	assert 55 in echoes, 'no echo after the malformed flood — a bad frame faulted the rx path'

	// ---- E2E-protected rx (BenchCmdSafe): checked BEFORE unpack ----
	// the echo sums both rx levels; the plain level rests at 55 here, so the
	// protected legs live in a disjoint range (echo = 55 + safe level)
	mut prot := e2e.TxState{}
	// a properly protected frame is accepted end to end
	c.write_to(app_addr, safe_cmd_datagram(mut prot, 100))!
	echoes = drain_echoes(mut c, 2000 * time.millisecond)
	assert 155 in echoes, 'no echo of the protected level — the E2E-checked rx path is broken'
	// a tampered payload (CRC no longer matches) is a counted drop, and the
	// good frame after it still lands (the rx state survives a bad frame)
	mut bad := safe_cmd_datagram(mut prot, 7)
	bad[someip.header_len] = 9 // flip the level AFTER protect: CRC now lies
	c.write_to(app_addr, bad)!
	c.write_to(app_addr, safe_cmd_datagram(mut prot, 110))!
	echoes = drain_echoes(mut c, 2000 * time.millisecond)
	assert 62 !in echoes && 64 !in echoes, 'a tampered protected frame was decoded (E2E rx check dead)'
	assert 165 in echoes, 'no echo after the tampered frame — a bad trailer wedged the protected path'

	// the refusals must have been COUNTED, not merely not-echoed: the drop
	// counter's observable face is the rate-limited stderr notice, printed
	// only when the count advances — silence here means the counter is dead
	p.signal_kill()
	p.wait()
	errout := p.stderr_slurp()
	assert errout.contains('someip: rx drops counted'), 'no drop notice on stderr — refusals were not counted (REQ-NET-015/017)'
}

// safe_cmd_datagram builds a BenchCmdSafe notification: one level byte behind
// the configured E2E trailer (data_id 0x22, ctr@1, crc@2) — protected through
// the REAL comm/e2e, so the probe stamps exactly what the bridge checks.
fn safe_cmd_datagram(mut tx e2e.TxState, level u8) []u8 {
	h := someip.notification(service, id_cmd_safe, iface_ver, 3)
	mut d := []u8{len: someip.header_len + 3}
	someip.encode(h, unsafe { &d[0] })
	d[someip.header_len] = level
	tx.protect(unsafe { &d[someip.header_len] }, 3, 0x22, 2, 1)
	return d
}
