module main

// system_full entry point. The generated gen/loom_gen.v provides run() (the FB superloop),
// thread creation, and tx_application_define for ThreadX initialization.

import gen

fn C.board_clock_init()          // PLL1 clock setup
fn C.board_can_clock_pins_init() // FDCAN kernel clock + pin AF

fn main() {
	C.board_clock_init()
	C.board_can_clock_pins_init()
	gen.boot() // hands off to ThreadX kernel enter; never returns
}
