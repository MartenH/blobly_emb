// NM coordination demo: two nodes (A, B) on can0 sharing a bus, timings from
// ecu.toml (gen.nm_can0_*). Shows the bus staying awake while EITHER node needs
// it, the hand-off between them, and both timing out to sleep once neither does.
// Pure simulation (no CAN needed): a node that transmits is "heard" by the other.
module main

import comm.nm
import gen

fn main() {
	t := nm.Timings{
		msg_cycle_us:  gen.nm_can0_msg_cycle_us
		timeout_us:    gen.nm_can0_timeout_us
		repeat_us:     gen.nm_can0_repeat_us
		wait_sleep_us: gen.nm_can0_wait_sleep_us
	}
	mut a := nm.Nm{
		cfg: t
	}
	mut b := nm.Nm{
		cfg: t
	}

	println('NM coordination on can0 (timings from ecu.toml):')
	println('  A requests @0ms, hands off to B @500ms, B releases @1000ms')
	step := u64(25_000) // 25 ms
	mut last := ''
	mut now := u64(0)
	for now <= 2_000_000 {
		match now {
			0 { a.request(now) } // A needs the bus
			500_000 { a.release(); b.request(now) } // hand-off: B now needs it
			1_000_000 { b.release() } // nobody needs it anymore
			else {}
		}
		tx_a := a.tick(now)
		tx_b := b.tick(now)
		if tx_a { b.on_rx(now) } // each node hears the other's NM frames
		if tx_b { a.on_rx(now) }

		bus := if a.awake() || b.awake() { 'AWAKE' } else { 'asleep' }
		line := 'A=${a.state} B=${b.state} bus=${bus}'
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
