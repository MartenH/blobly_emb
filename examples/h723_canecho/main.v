module main

// Bare-metal CAN echo on the STM32H723 (Nucleo-H723ZG + CAN-FD Click). board.c
// brings up both FDCAN1 (PD1=TX/PD0=RX) and FDCAN2 (PB6=TX/PB12=RX), AF9, on the
// 8 MHz HSE kernel clock. This loop opens BOTH buses and echoes every received
// classic frame back with id+1 — so the Click works in either socket without a
// rebuild, and a bench tool (candump/cansend on the PCAN) sees a distinct reply.
//
// The H723 is the same H72x/H73x family as the H735, but on a Nucleo-144 it shares
// the H755's 8 MHz HSE and Click FDCAN pins — so pin-mux + kernel-clock init match
// h755_canfd, no PLL needed: SYSCLK stays on the HSI reset default, FDCAN kclk = HSE.
//
// Entry is main__main() from startup.c (no V _vinit), the bare-metal pattern.

import driver.can

fn C.board_can_clock_pins_init()

fn echo(f can.Frame) can.Frame {
	mut out := can.Frame{
		id:  f.id + 2 // reply id = request id + 2 — distinguishes this node from the
		// H735's canecho (id+1) when both sit on one bus
		len: f.len
		ext: f.ext // preserve the request's id width
	}
	for i in 0 .. int(f.len) {
		out.data[i] = f.data[i]
	}
	return out
}

fn main() {
	C.board_can_clock_pins_init()

	mut ch1 := can.Channel{} // bus 0 = FDCAN1 (PD0/PD1)
	mut ch2 := can.Channel{} // bus 1 = FDCAN2 (PB6/PB12)
	ok1 := ch1.open('0', false) // classic 500 kbit/s
	ok2 := ch2.open('1', false)
	if !ok1 && !ok2 {
		for {} // neither bus opened (kernel clock?) — halt so a debugger stops here
	}

	mut f := can.Frame{}
	for {
		if ok1 && ch1.recv(mut f) {
			ch1.send(echo(f))
		}
		if ok2 && ch2.recv(mut f) {
			ch2.send(echo(f))
		}
	}
}
