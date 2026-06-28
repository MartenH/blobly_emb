module main

// Bare-metal CAN echo on the STM32H735G-DK. board.c brings up FDCAN1
// (PH13 = TX, PH14 = RX, AF9) on a 25 MHz HSE kernel clock; this loop opens the
// bus and echoes every received classic frame back with id+1, so a bench tool
// (candump/cansend on a PCAN/Kvaser) sees a distinct reply for each frame it sends.
//
// Entry is main__main() called directly from startup.c (no V _vinit) — the same
// bare-metal pattern proven by h735_blinky.

import driver.can

fn C.board_can_clock_pins_init()

fn main() {
	C.board_can_clock_pins_init()

	mut ch := can.Channel{}
	if !ch.open('0', false) { // bus index 0 = FDCAN1, classic 500 kbit/s
		for {} // open/init failed (kernel clock?) — halt so a debugger stops here
	}

	mut f := can.Frame{}
	for {
		if ch.recv(mut f) {
			mut out := can.Frame{
				id:  f.id + 1 // reply id = request id + 1 -> visibly an echo
				len: f.len
			}
			for i in 0 .. int(f.len) {
				out.data[i] = f.data[i]
			}
			ch.send(out)
		}
	}
}
