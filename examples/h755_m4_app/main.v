module main

// h755_m4_app — the GENERATED satellite image on the H755's Cortex-M4 (multi-image
// codegen, docs/multi-image.md). Everything that used to be hand-written here lives in
// gen/loom_gen.v now, emitted by the OWNER example's generator run (`make gen` in
// examples/h755_threadx — its ecu.toml declares this whole node, partition "m4"). This
// example keeps only what every example owns: the FBs (app/), the board/platform glue C
// (m4_glue.c), the Makefile, and this shim.
import gen
import osal.vrt as _ // V's builtin hooks on target

// entry is the image's entry point: crt0.S jumps to it by its exported C name (BOARD_ENTRY)
// after bss/data init. Not V's `fn main`, which V3 wraps in a hosted C main (VEXE env setup,
// _vinit); the image enters by a name it owns, never by V's mangling of `main`.
@[export: 'blob_entry']
fn entry() {
	gen.boot() // park on clocks-ready -> timebase -> xioc pool -> trace arm -> kernel
}

// main is never called on target (crt0 enters at `entry`); V requires one in module main
fn main() {
	entry()
}
