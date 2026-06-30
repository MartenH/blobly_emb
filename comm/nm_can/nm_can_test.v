module nm_can

import comm.nm
import driver.can

// A fixed-size in-memory CAN endpoint — satisfies Transport with no heap, so the
// binding runs deterministically without a real vcan interface.
struct FakeBus {
mut:
	rx      [32]can.Frame
	rx_n    int
	rx_head int
	tx      [32]can.Frame
	tx_n    int
}

fn (mut b FakeBus) recv(mut f can.Frame) bool {
	if b.rx_head >= b.rx_n {
		return false
	}
	src := b.rx[b.rx_head]
	b.rx_head++
	f.id = src.id
	f.len = src.len
	f.data = src.data
	return true
}

fn (mut b FakeBus) send(f can.Frame) bool {
	if b.tx_n >= 32 {
		return false
	}
	b.tx[b.tx_n] = f
	b.tx_n++
	return true
}

// cross-deliver: a node hears the others' transmissions, not its own echo. Moves
// `from`'s outbox into `to`'s inbox and clears the sender's outbox.
fn deliver(mut from FakeBus, mut to FakeBus) {
	for i in 0 .. from.tx_n {
		if to.rx_n < 32 {
			to.rx[to.rx_n] = from.tx[i]
			to.rx_n++
		}
	}
	from.tx_n = 0
}

fn frame_bytes(f can.Frame) [8]u8 {
	mut b := [8]u8{}
	for i in 0 .. 8 {
		b[i] = f.data[i]
	}
	return b
}

fn push_rx(mut bus FakeBus, id u32, bytes [8]u8) {
	mut f := can.Frame{
		id:  id
		len: 8
	}
	for i in 0 .. 8 {
		f.data[i] = bytes[i]
	}
	if bus.rx_n < 32 {
		bus.rx[bus.rx_n] = f
		bus.rx_n++
	}
}

fn timings() nm.Timings {
	return nm.Timings{
		msg_cycle_us:  100
		timeout_us:    300
		repeat_us:     200
		wait_sleep_us: 150
	}
}

fn cfg(node_id u8, tx_id u32) Config {
	return Config{
		node_id: node_id
		tx_id:   tx_id
		rx_lo:   0x500
		rx_hi:   0x5FF
	}
}

// @verifies REQ-NM-003, REQ-NM-004, REQ-NM-012, REQ-NM-013
// Two nodes hand the bus off over REAL encoded NM frames on a shared (fake) bus,
// then both sleep once neither needs it — the on-wire glue, end to end.
fn test_two_node_handoff_over_frames() {
	mut la := Link{
		cfg: cfg(1, 0x500)
		sm:  nm.Nm{
			cfg: timings()
		}
	}
	mut lb := Link{
		cfg: cfg(2, 0x501)
		sm:  nm.Nm{
			cfg: timings()
		}
	}
	mut ba := FakeBus{}
	mut bb := FakeBus{}

	mut now := u64(0)
	mut woke_b_via_frame := false
	mut both_awake_handoff := false

	for now <= 4000 {
		match now {
			0 { la.request(now) } // A needs the bus
			1000 { // hand-off: A releases, B takes over
				la.release()
				lb.request(now)
			}
			2000 { lb.release() } // nobody needs it anymore
			else {}
		}
		la.service(mut ba, now)
		lb.service(mut bb, now)

		if now > 0 && now < 1000 && lb.awake() {
			woke_b_via_frame = true // B woke purely from hearing A's frame
		}
		if now == 1500 && la.awake() && lb.awake() {
			both_awake_handoff = true
		}

		// shared bus: deliver each node's sends to the other for the next round
		ba.rx_n = 0
		ba.rx_head = 0
		bb.rx_n = 0
		bb.rx_head = 0
		deliver(mut ba, mut bb)
		deliver(mut bb, mut ba)
		now += 50
	}

	assert woke_b_via_frame, "B should wake from A's NM frame on the bus"
	assert both_awake_handoff, 'bus should stay awake across the A->B hand-off'
	assert !la.awake(), 'A should be asleep once neither node needs the bus'
	assert !lb.awake(), 'B should be asleep once neither node needs the bus'
}

// @verifies REQ-NM-011, REQ-NM-013
// The bytes actually put on the bus carry our NID and the active-wakeup CBV when
// we are the one that woke the network.
fn test_active_waker_frame_bytes() {
	mut l := Link{
		cfg: cfg(7, 0x507)
		sm:  nm.Nm{
			cfg: timings()
		}
	}
	mut b := FakeBus{}

	l.request(0) // active wakeup from sleep
	l.service(mut b, 0) // -> repeat_message, armed -> transmits

	assert b.tx_n >= 1, 'an active waker must transmit its NM frame'
	assert b.tx[0].id == 0x507, 'frame goes out on our configured NM id'
	f := nm.parse_frame(frame_bytes(b.tx[0]))
	assert f.nid == 7, 'NID byte must be our node id'
	assert f.cbv & nm.cbv_active_wakeup != 0, 'active waker sets the active-wakeup bit'
}

// @verifies REQ-NM-012
// A node that needs nothing but is woken by another's frame still announces in
// repeat_message, and its frame advertises ready-to-sleep (not active-wakeup).
fn test_passive_node_advertises_ready_to_sleep() {
	mut l := Link{
		cfg: cfg(9, 0x509)
		sm:  nm.Nm{
			cfg: timings()
		}
	}
	mut b := FakeBus{}

	// another node's NM frame arrives -> passive wakeup
	other := nm.Frame{
		nid: 3
	}
	push_rx(mut b, 0x500, other.to_bytes())
	l.service(mut b, 0)

	assert b.tx_n >= 1, 'a passively-woken node still announces in repeat_message'
	f := nm.parse_frame(frame_bytes(b.tx[0]))
	assert f.nid == 9
	assert f.cbv & nm.cbv_ready_to_sleep != 0, 'a node needing nothing advertises ready-to-sleep'
	assert f.cbv & nm.cbv_active_wakeup == 0, 'passive wake must not set active-wakeup'
}

// out-of-range and own-echo frames must be ignored by the binding.
fn test_ignores_out_of_range_and_own_id() {
	mut l := Link{
		cfg: cfg(5, 0x505)
		sm:  nm.Nm{
			cfg: timings()
		}
	}
	mut b := FakeBus{}

	// a non-NM id and our own id must not wake us
	push_rx(mut b, 0x100, nm.Frame{ nid: 8 }.to_bytes()) // below rx_lo
	push_rx(mut b, 0x505, nm.Frame{ nid: 5 }.to_bytes()) // our own tx id
	l.service(mut b, 0)

	assert !l.awake(), 'frames outside the NM range / our own id must not wake the node'
}
