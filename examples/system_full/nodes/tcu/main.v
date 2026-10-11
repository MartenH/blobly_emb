module main

// tcu (H723 telematics/eth node) entry. The generated gen/loom_gen.v provides the
// FB thread, the SOME/IP eth comm thread (over the NetX seam driver/eth/eth_netx.c)
// and @[export] tx_application_define. This hand-written, platform-aware main does
// only the board bring-up then hands control to the ThreadX kernel. crt0.S calls
// blob_entry (main.v's exported entry).
import gen
import osal.vrt as _ // V's builtin hooks on target

fn C.board_clock_init() // H723: 400 MHz PLL1 (boards/h723/board.c)

// entry is the image's entry point: crt0.S jumps to it by its exported C name (BOARD_ENTRY)
// after bss/data init. Not V's `fn main`, which V3 wraps in a hosted C main (VEXE env setup,
// _vinit); the image enters by a name it owns, never by V's mangling of `main`.
@[export: 'blob_entry']
fn entry() {
	C.board_clock_init()
	gen.boot() // hands off to ThreadX (kernel enter -> tx_application_define); never returns
}

// main is never called on target (crt0 enters at `entry`); V requires one in module main
fn main() {
	entry()
}
