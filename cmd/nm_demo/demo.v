// NM coordination demo, ON THE WIRE: two nodes (A, B) run the real NM-over-CAN
// binding (comm/nm_can) on vcan0 — every presence message is an actual 8-byte NM
// frame encoded, sent on the bus, received by the other node, and decoded back
// into the state machine. Shows the bus staying awake while EITHER node needs it,
// the hand-off between them, and both timing out to sleep once neither does.
//
// Needs vcan0 up:  sudo modprobe vcan && sudo ip link add vcan0 type vcan && sudo ip link set vcan0 up
module main

import comm.nm
import comm.nm_can
import driver.can

fn main() {
	// Timings mirror the docs/nm.md [nm.can0] example (ms -> µs). In a real app
	// these come from ecu.toml via cfg2v as gen.nm_can0_* constants.
	t := nm.Timings{
		msg_cycle_us:  100_000
		timeout_us:    300_000
		repeat_us:     200_000
		wait_sleep_us: 150_000
	}

	// Each node opens its own socket on the shared bus. SocketCAN delivers a
	// frame to the OTHER sockets on the interface, not the sender — exactly the
	// "hear the others" model NM needs.
	mut ca := can.Channel{}
	mut cb := can.Channel{}
	if !ca.open('vcan0', false) || !cb.open('vcan0', false) {
		eprintln('need vcan0 up: sudo modprobe vcan && sudo ip link add vcan0 type vcan && sudo ip link set vcan0 up')
		return
	}

	mut a := nm_can.Link{
		cfg: nm_can.Config{
			node_id: 1
			tx_id:   0x500
			rx_lo:   0x500
			rx_hi:   0x5ff
		}
		sm:  nm.Nm{
			cfg: t
		}
	}
	mut b := nm_can.Link{
		cfg: nm_can.Config{
			node_id: 2
			tx_id:   0x501
			rx_lo:   0x500
			rx_hi:   0x5ff
		}
		sm:  nm.Nm{
			cfg: t
		}
	}

	println('NM on vcan0 (real NM frames, timings from ecu.toml):')
	println('  A requests @0ms, hands off to B @500ms, B releases @1000ms')
	step := u64(25_000) // 25 ms
	mut last := ''
	mut now := u64(0)
	for now <= 2_000_000 {
		match now {
			0 { a.request(now) } // A needs the bus
			500_000 { // hand-off: B now needs it
				a.release()
				b.request(now)
			}
			1_000_000 { b.release() } // nobody needs it anymore
			else {}
		}
		// each node services its socket: drain rx -> state machine, then tx if due
		sa := a.service(mut ca, now)
		sb := b.service(mut cb, now)

		bus := if a.awake() || b.awake() { 'AWAKE' } else { 'asleep' }
		line := 'A=${sa} B=${sb} bus=${bus}'
		if line != last {
			println('  t=${now / 1000:4}ms  ${line}')
			last = line
		}
		now += step
	}

	asleep := !a.awake() && !b.awake()
	println('final: ' + if asleep {
		'bus asleep — neither node needs it, both timed out to sleep'
	} else {
		'STILL AWAKE (unexpected)'
	})
}
