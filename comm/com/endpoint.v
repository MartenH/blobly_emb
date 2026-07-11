module com

// The endpoint schema — a platform module's wire ports, declared as data next to the code that
// serves them (docs/com-modules.md). Each module exports `pub const endpoints`; the generator
// (tools/loom2v) imports it to validate the ecu.toml bindings, emit the router match arms
// (endpoint `x` is served by method `on_x` — the convention is mechanical), and pass tx bindings
// to the module constructor. The target never iterates this: it is generator input, zero runtime
// cost, and drift is self-catching (unknown binding fails generation; a schema endpoint without
// its on_<name> method fails to compile in the generated output).

pub enum Dir {
	rx
	tx
	rxtx
}

pub struct Endpoint {
pub:
	name string
	dir  Dir
	dlc  u8 // payload bytes this endpoint sends/expects (0 = flexible)
	doc  string
}
