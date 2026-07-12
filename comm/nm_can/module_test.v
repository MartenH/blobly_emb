module nm_can

// @verifies REQ-NM-002 REQ-NM-003 REQ-NM-004 REQ-NM-006 REQ-NM-008

import comm.nm
import driver.can

// The push-model module under the bus owner's contract: on_peers gets routed rx frames,
// produce is drained for tx. Timings are µs-scale so the tests are instant.
const t_cycle = u64(100)
const t_timeout = u64(300)
const t_repeat = u64(200)
const t_wait = u64(150)

fn mk() NmModule {
	mut m := NmModule{}
	m.init(0x12, 0x512, 0, nm.Timings{
		msg_cycle_us:  t_cycle
		timeout_us:    t_timeout
		repeat_us:     t_repeat
		wait_sleep_us: t_wait
	})
	return m
}

fn peer_frame(id u32) can.Frame {
	mut f := can.Frame{}
	f.id = id
	f.len = 8
	f.data[0] = 0x07 // peer NID
	return f
}

// wake on local request -> announce on the bound tx id, active-wakeup bit set, then
// periodic every msg_cycle while requested (REQ-NM-004, REQ-NM-008).
fn test_request_announces_and_cycles() {
	mut m := mk()
	mut f := can.Frame{}
	assert !m.produce(0, mut f) // asleep, silent
	m.request(1000)
	assert m.produce(1000, mut f) // announce immediately on wake
	assert f.id == 0x512
	assert f.len == 8
	assert f.data[0] == 0x12 // our NID
	assert f.data[1] & nm.cbv_active_wakeup != 0 // we woke the bus
	assert !m.produce(1000 + t_cycle / 2, mut f) // not due yet
	assert m.produce(1000 + t_cycle, mut f) // one per cycle
}

// released + silent bus -> ready_sleep -> timeout -> prepare -> bus_sleep, transmitting
// nothing on the way down (REQ-NM-002, REQ-NM-006).
fn test_release_then_timeout_sleeps_silently() {
	mut m := mk()
	mut f := can.Frame{}
	m.request(0)
	assert m.produce(0, mut f)
	m.release()
	// the wake-announce (repeat_message) phase completes even when already released —
	// its remaining transmissions are legitimate; drive through it cycle by cycle.
	m.produce(t_cycle, mut f)
	m.produce(t_repeat, mut f) // final repeat tx + transition (last activity = t_repeat)
	assert !m.produce(t_repeat + t_cycle, mut f) // ready_sleep: silent
	assert m.state() == .ready_sleep
	assert !m.produce(t_repeat + t_timeout, mut f) // timeout since the last activity
	assert m.state() == .prepare_bus_sleep
	assert !m.produce(t_repeat + t_timeout + t_wait, mut f)
	assert m.state() == .bus_sleep
}

// peer NM traffic keeps a released node awake (REQ-NM-003); our own echo does not.
fn test_peer_traffic_holds_awake_echo_does_not() {
	mut m := mk()
	mut f := can.Frame{}
	m.request(0)
	assert m.produce(0, mut f)
	m.release()
	m.produce(t_cycle, mut f)
	m.produce(t_repeat, mut f) // finish the announce phase -> ready_sleep
	mut now := t_repeat
	for _ in 0 .. 10 { // keep feeding peer frames well past the timeout
		now += t_timeout / 2
		m.on_peers(now, peer_frame(0x507))
		assert !m.produce(now, mut f)
		assert m.state() == .ready_sleep // held awake by the peer
	}
	// our own tx id must NOT count as peer activity
	now += t_timeout / 2
	m.on_peers(now, peer_frame(0x512))
	now += t_timeout
	assert !m.produce(now, mut f)
	assert m.state() == .prepare_bus_sleep // echo ignored -> timed out
}

// a peer frame wakes a sleeping node passively: it announces WITHOUT active-wakeup (REQ-NM-004).
fn test_passive_wake() {
	mut m := mk()
	mut f := can.Frame{}
	m.on_peers(5000, peer_frame(0x507))
	assert m.state() == .repeat_message
	assert m.produce(5000, mut f)
	assert f.data[1] & nm.cbv_active_wakeup == 0 // woken by the bus, not by us
}
