module sig

// Signal value types — the typed contract shared by Function Blocks, the COM
// codec, and the generated wiring. No dependencies (so app/ and gen/ can both
// import it without a cycle). No heap.
//
// The generated per-FB *In / *Out port structs live alongside this in
// sig/ports_gen.v (tools/loom2v).

pub struct VehicleSpeed {
pub mut:
	kph   u16
	valid bool
}

pub struct WarnLamp {
pub mut:
	on bool
}
