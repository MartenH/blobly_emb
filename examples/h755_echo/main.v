module main

// Bare-metal CAN echo on the NUCLEO-H755ZI-Q (CM7) — the boards/h755zi smoke test.
// board.c brings up FDCAN1 on PD0 = RX / PD1 = TX (AF9, Zio CN9), kernel clock HSE
// 8 MHz from the ST-LINK MCO, through an external TLE9251V transceiver on jumper
// wires. The loop echoes every received classic frame back with id+1, so the bench
// (candump/cansend on the PCAN) sees a distinct reply per frame — the same first-
// contact ritual the H735 bench started with (h735_canecho).

import driver.can

fn C.board_clock_init()
fn C.board_can_clock_pins_init()

fn main() {
	C.board_clock_init() // M7 -> 400 MHz (Direct SMPS + VOS1); FDCAN clock stays HSE 8 MHz
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
