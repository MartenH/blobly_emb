module main

// h755_m4_app — the GENERATED satellite image on the H755's Cortex-M4 (multi-image
// codegen, docs/multi-image.md). Everything that used to be hand-written here lives in
// gen/loom_gen.v now, emitted by the OWNER example's generator run (`make gen` in
// examples/h755_threadx — its ecu.toml declares this whole node, partition "m4"). This
// example keeps only what every example owns: the FBs (app/), the board/platform glue C
// (m4_glue.c), the Makefile, and this shim.
import gen

fn main() {
	gen.boot() // park on clocks-ready -> timebase -> xioc pool -> trace arm -> kernel
}
