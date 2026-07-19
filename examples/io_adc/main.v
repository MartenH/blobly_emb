module main

// Platform entry: the io thread + app partition are generated from ecu.toml.
// run() configures + inits io before any app code (REQ-IO-009); the host driver
// mirrors pins to io/<name> — poke the analog input with `echo 3000 > io/PotVolt`
// and watch `cat io/LedHi` flip to 1.

import gen

fn main() {
	println('io_adc: io@c0 (PotVolt PA3 adc -> LedHi PB0) | app@c0 Meter')
	gen.run()
}
