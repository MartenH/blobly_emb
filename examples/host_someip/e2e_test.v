module main

// e2e: build the example, run the binary, and listen on the configured peer
// endpoint (127.0.0.1:30491) — the io e2e pattern carried to the eth bus
// (proven-on-lo, docs/someip.md). Every datagram is decoded and gated by the
// REAL rx envelope code (comm/someip check_event), then the three COM tx
// modes are each asserted by their observable wire behavior:
//   cyclic (0x8001): keeps a steady cadence regardless of payload change;
//   event  (0x8002): sends ONLY on change — every consecutive pair differs;
//   mixed  (0x8003): heartbeats between changes — repeats AND changes appear.
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

	// collect ~3.2 s of traffic (nominal: 32 cyclic, ~6 event, ~10+4 mixed)
	mut by_id := map[u16][][]u8{}
	mut buf := []u8{len: 2048}
	start := time.now()
	for time.since(start) < 3200 * time.millisecond {
		n, _ := c.read(mut buf) or { continue }
		if n < someip.header_len {
			continue
		}
		h, ok := someip.decode(unsafe { &buf[0] }, n)
		assert ok
		// the REAL envelope gate accepts every datagram the image emits
		assert someip.check_event(h, n, service, iface_ver) == someip.Drop.none, 'dropped: ${h}'
		by_id[h.method] << buf[someip.header_len..n].clone()
	}

	ncyc := (by_id[id_cyclic] or { [][]u8{} }).len
	evs := by_id[id_event] or { [][]u8{} }
	mixed := by_id[id_mixed] or { [][]u8{} }

	// cyclic: a steady stream — nominal 32 in the window; generous floor for a
	// loaded host, and it must dominate the change-driven frames
	assert ncyc >= 15, 'cyclic: only ${ncyc} datagrams'
	assert ncyc > evs.len, 'cyclic (${ncyc}) must outnumber event (${evs.len})'

	// event: only on change — nominal ~6; every consecutive pair DIFFERS
	assert evs.len >= 3 && evs.len <= 12, 'event: ${evs.len} datagrams'
	for i in 1 .. evs.len {
		assert evs[i] != evs[i - 1], 'event sent an unchanged payload'
	}

	// mixed: heartbeat + change — nominal ~14; both repeats (the heartbeat
	// resending an unchanged value) and changes must appear on the wire
	assert mixed.len >= 8, 'mixed: only ${mixed.len} datagrams'
	mut repeats := 0
	mut changes := 0
	for i in 1 .. mixed.len {
		if mixed[i] == mixed[i - 1] {
			repeats++
		} else {
			changes++
		}
	}
	assert repeats >= 2, 'mixed: no heartbeat repeats observed (${repeats})'
	assert changes >= 2, 'mixed: no change-driven sends observed (${changes})'
}
