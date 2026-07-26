module main

// domain_m4 — the GENERATED satellite image on the system_full domain node's Cortex-M4
// (multi-image codegen, docs/multi-image.md). The OWNER node (../domain) declares this whole
// node in its ecu.toml (partition "dynamics", image = "../domain_m4"); the owner's `make gen`
// emits gen/loom_gen.v here. This dir owns only the FBs (app/), the board/platform glue
// (m4_glue.c), the Makefile, and this shim.
import gen

fn main() {
	gen.boot() // park on clocks-ready -> timebase -> xioc pool -> kernel
}
