module main

// domain_m4 — the GENERATED satellite image on the system_full domain node's Cortex-M4
// (multi-image codegen, docs/multi-image.md). The OWNER node (../domain) declares this whole
// node in its ecu.toml (partition "dynamics", image = "../domain_m4"); the owner's `make gen`
// emits gen/loom_gen.v here. This dir owns only the FBs (app/), the board/platform glue
// (m4_glue.c), the Makefile, and this shim.
import gen
import osal.vrt as _ // V's builtin hooks on target

// entry is the image's entry point: crt0.S jumps to it by its exported C name (BOARD_ENTRY)
// after bss/data init. Not V's `fn main`, which V3 wraps in a hosted C main (VEXE env setup,
// _vinit); the image enters by a name it owns, never by V's mangling of `main`.
@[export: 'blob_entry']
fn entry() {
	gen.boot() // park on clocks-ready -> timebase -> xioc pool -> kernel
}

// main is never called on target (crt0 enters at `entry`); V requires one in module main
fn main() {
	entry()
}
