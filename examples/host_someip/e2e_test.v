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
//   event  (0x8002): sends on change ONLY, and EVERY transition — decoded
//     levels are strictly consecutive (+1, no skips, no repeats);
//   mixed  (0x8003): heartbeats between changes AND publishes a change
//     immediately — some transition must arrive well inside the 300 ms
//     heartbeat interval.
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
		assert r.pay[0] == u8(q % 100), 'cyclic field relation (load vs ticks)'
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

	// ---- event: change-only, EVERY transition, for the WHOLE window ----
	// ~7 transitions at 500 ms in 3.5 s: a sender that stops early fails both
	// the floor and the last-arrival bound
	assert evs.len >= 5 && evs.len <= 12, 'event: ${evs.len} datagrams (expected ~7)'
	assert evs.last().at - start > 2200 * time.millisecond, 'event publication stopped early'
	for i, r in evs {
		assert r.pay.len == 1, 'event payload ${r.pay.len} bytes'
		if i > 0 {
			// strictly consecutive levels: a skipped transition (or an
			// unchanged resend) is a mode violation either way
			assert r.pay[0] == evs[i - 1].pay[0] + 1, 'event levels ${evs[i - 1].pay[0]} -> ${r.pay[0]} (must be +1)'
		}
	}

	// ---- mixed: heartbeat repeats AND immediate-on-change ----
	assert mixed.len >= 8, 'mixed: only ${mixed.len} datagrams'
	mut repeats := 0
	mut paced_repeats := 0
	mut fast_change := false
	for i, r in mixed {
		assert r.pay.len == 2, 'mixed payload ${r.pay.len} bytes'
		if i > 0 {
			prev := mixed[i - 1]
			if le16(r.pay, 0) == le16(prev.pay, 0) {
				repeats++
				// heartbeat pacing: repeats arrive at the CONFIGURED 300 ms —
				// a fast-cyclic impostor (whose 'immediate' changes are just a
				// short cycle) shows short repeat gaps here and fails
				if r.at - prev.at > 240 * time.millisecond {
					paced_repeats++
				}
			} else {
				assert le16(r.pay, 0) == le16(prev.pay, 0) + 1, 'mixed setpoint skipped a step'
				// an off-cycle change must be published BEFORE the next
				// heartbeat — a purely cyclic sender shows ~300 ms gaps only
				if r.at - prev.at < 220 * time.millisecond {
					fast_change = true
				}
			}
		}
	}
	assert repeats >= 2, 'mixed: no heartbeat repeats observed (${repeats})'
	assert paced_repeats >= 2, 'mixed: heartbeat repeats not paced at the configured cycle (${paced_repeats})'
	assert fast_change, 'mixed: no change arrived inside the heartbeat interval — immediate-on-change is missing'
}
