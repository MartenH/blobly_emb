module main

// Bare-metal two-bus CAN-FD echo on the STM32H755 (Nucleo-H755ZI-Q + MikroE
// Click Shield for Nucleo-144). board.c brings up FDCAN1 (PD1 = TX, PD0 = RX) and
// FDCAN2 (PB6 = TX, PB12 = RX), both AF9, on an 8 MHz HSE kernel clock. Each
// received classic frame is echoed back on its own bus with id+1.
//
// Hardware: two CAN FD 3 Clicks (MIKROE-3992, TLE9251V transceivers) in shield
// sockets 1 and 3 for power/ground; their edge RX/TX headers wire to the FDCAN
// pins above (the socket UART pins aren't FDCAN-capable — see README).
//
// Entry is main__main() called directly from startup.c (no V _vinit), the same
// bare-metal pattern proven by h735_blinky / h735_canecho.

import driver.can

fn C.board_can_clock_pins_init()

fn main() {
	C.board_can_clock_pins_init()

	mut ch1 := can.Channel{} // bus 0 = FDCAN1
	mut ch2 := can.Channel{} // bus 1 = FDCAN2
	if !ch1.open('0', false) || !ch2.open('1', false) {
		for {} // open/init failed (clock?) — halt so a debugger stops here
	}

	mut f := can.Frame{}
	for {
		if ch1.recv(mut f) {
			ch1.send(echo(f))
		}
		if ch2.recv(mut f) {
			ch2.send(echo(f))
		}
	}
}

// echo returns the frame with id+1 and the same payload, so a bench tool sees a
// distinct reply per bus for each frame it sends.
fn echo(f can.Frame) can.Frame {
	mut out := can.Frame{
		id:  f.id + 1
		len: f.len
		ext: f.ext // preserve the request's id width — a 29-bit request echoes as 29-bit
	}
	for i in 0 .. int(f.len) {
		out.data[i] = f.data[i]
	}
	return out
}
