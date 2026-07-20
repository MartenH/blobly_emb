module main

// h735_someip entry (docs/someip.md target rung). The generated gen/loom_gen.v
// provides the FB thread, the SOME/IP eth comm thread (over the NetX seam in
// driver/eth/eth_netx.c) and @[export] tx_application_define. This hand-written,
// platform-aware main does only the board bring-up then hands control to the
// ThreadX kernel. crt0.S calls main__main (V's `fn main` body).
import gen

fn C.board_clock_init() // 550 MHz PLL1

fn main() {
	C.board_clock_init()
	gen.boot() // hands off to ThreadX (kernel enter -> tx_application_define); never returns
}
