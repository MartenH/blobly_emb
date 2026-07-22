module main

// Bare-metal CAN echo on the STM32H723 (Nucleo-H723ZG + CAN-FD Click). board.c
// brings up FDCAN1 (PD1 = TX, PD0 = RX) and FDCAN2 (PB6 = TX, PB12 = RX), AF9, on
// the 8 MHz HSE kernel clock. This loop opens BOTH buses and echoes every received
// REQUEST frame back with id + 0x102, so a bench tool (candump/cansend on the PCAN)
// sees a distinct reply per frame, and the Click works in either socket.
//
// Reply id = request + 0x102:
//   - the +0x100 lifts the reply OUT of the echoed request range, so a reply is never
//     itself echoed. A node never receives its own frames, but two echo nodes sharing
//     one bus would otherwise ping-pong each other's replies forever.
//   - the +2 identifies this node; h735_canecho replies +1.
// Frames above the request range are ignored rather than echoed, so a reply can never
// overflow the 11-bit / 29-bit identifier and wrap around to a low id.
//
// The H723 is the same H72x/H73x family as the H735, but on a Nucleo-144 it shares
// the H755's 8 MHz HSE and Click FDCAN pins — so pin-mux + kernel-clock init match
// h755_canfd, no PLL needed: SYSCLK stays on the HSI reset default, FDCAN kclk = HSE.
//
// Entry is main__main() from startup.c (no V _vinit), the bare-metal pattern.

import driver.can

fn C.board_can_clock_pins_init()

const reply_off = u32(0x102)
const req_max_std = u32(0x6fd) // + 0x102 stays inside the 11-bit range
const req_max_ext = u32(0x1fff_fefd) // + 0x102 stays inside the 29-bit range

// is_request reports whether this frame is one to answer: inside the request range, so
// the reply lands outside it (never re-echoed) and cannot overflow the id width.
fn is_request(f can.Frame) bool {
	return if f.ext { f.id <= req_max_ext } else { f.id <= req_max_std }
}

fn echo(f can.Frame) can.Frame {
	mut out := can.Frame{
		id:  f.id + reply_off
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
		if ok1 && ch1.recv(mut f) && is_request(f) {
			ch1.send(echo(f))
		}
		if ok2 && ch2.recv(mut f) && is_request(f) {
			ch2.send(echo(f))
		}
	}
}
