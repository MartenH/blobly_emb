module main

// system_full entry point. The generated gen/loom_gen.v provides run() (the FB superloop),
// thread creation, and tx_application_define for ThreadX initialization.

import gen
import osal.vrt as _ // V's builtin hooks on target

fn C.board_clock_init()          // PLL1 clock setup
fn C.board_can_clock_pins_init() // FDCAN kernel clock + pin AF

// entry is the image's entry point: crt0.S jumps to it by its exported C name (BOARD_ENTRY)
// after bss/data init. Not V's `fn main`, which V3 wraps in a hosted C main (VEXE env setup,
// _vinit); the image enters by a name it owns, never by V's mangling of `main`.
@[export: 'blob_entry']
fn entry() {
	C.board_clock_init()
	C.board_can_clock_pins_init()
	gen.boot() // hands off to ThreadX kernel enter; never returns
}

// main is never called on target (crt0 enters at `entry`); V requires one in module main
fn main() {
	entry()
}
