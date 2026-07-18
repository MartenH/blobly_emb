module main

// Platform entry: everything (the platform io thread + app partition) is
// generated from ecu.toml. run() declares + inits the io points before any
// app code executes (REQ-IO-009); the host driver mirrors pins to io/<name>
// (poke inputs with tools/ioset, watch outputs with cat).

import gen

fn main() {
	println('io_gpio: io@c0 (UserButton PC13 -> LedGreen PB0) | app@c0 ButtonLamp')
	gen.run()
}
