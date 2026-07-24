module main

// Bare-metal CAN echo on the STM32H735G-DK. board.c brings up FDCAN1
// (PH13 = TX, PH14 = RX, AF9) on a 25 MHz HSE kernel clock; this loop opens the
// bus and echoes every received classic frame back with id+1, so a bench tool
// (candump/cansend on a PCAN/Kvaser) sees a distinct reply for each frame it sends.
//
// Entry is main__main() called directly from startup.c (no V _vinit) — the same
// bare-metal pattern proven by h735_blinky.

import driver.can

fn C.board_clock_init()
fn C.board_can_clock_pins_init()

fn main() {
	C.board_clock_init() // M7 -> 550 MHz (Direct SMPS + VOS0); FDCAN clock stays HSE
	C.board_can_clock_pins_init()

	mut ch := can.Channel{}
	if !ch.open('0', false) { // bus index 0 = FDCAN1, classic 500 kbit/s
		for {} // open/init failed (kernel clock?) — halt so a debugger stops here
	}

	mut f := can.Frame{}
	for {
		if ch.recv(mut f) {
			// Answer ODD ids only; replies (+1) are even and therefore never re-answered.
			// Unconditional echo cascades the moment two echo nodes share a bus — each
			// answers the other's replies forever (codex #184). Parity chosen to keep this
			// example's own documented probes working — README: 0x123 -> 0x124, and the
			// recorded 0x001 -> 0x002 verification (codex #208 caught the first cut
			// inverting this). The +1 must also stay in range for the id width.
			max_id := if f.ext { u32(0x1fff_fffd) } else { u32(0x7fd) }
			if f.id & 1 == 0 || f.id > max_id {
				continue
			}
			mut out := can.Frame{
				id:  f.id + 1 // reply id = request id + 1 -> visibly an echo
				len: f.len
				ext: f.ext // preserve the request's id width — a 29-bit request echoes as 29-bit
			}
			for i in 0 .. int(f.len) {
				out.data[i] = f.data[i]
			}
			ch.send(out)
		}
	}
}
