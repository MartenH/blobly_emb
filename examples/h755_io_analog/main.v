module main

// h755_io_analog entry. The generated gen/loom_gen.v provides run() (the FB
// superloop), the io thread (ADC scan/DMA + PWM), and @[export] tx_application_define
// — which runs io cfg/init + the boot publish BEFORE any thread exists (REQ-IO-009),
// then creates the app + io + comm threads. This hand-written, platform-aware main
// does only the board bring-up then hands control to the ThreadX kernel. crt0.S
// calls blob_entry (main.v's exported entry).
import gen
import osal.vrt as _ // V's builtin hooks on target

fn C.board_clock_init()          // PLL1 to the board's max (boards/h755zi/board.c)
fn C.board_can_clock_pins_init() // FDCAN1 kernel clock + PD0/PD1 AF9

// entry is the image's entry point: crt0.S jumps to it by its exported C name (BOARD_ENTRY)
// after bss/data init. Not V's `fn main`, which V3 wraps in a hosted C main (VEXE env setup,
// _vinit); the image enters by a name it owns, never by V's mangling of `main`.
@[export: 'blob_entry']
fn entry() {
	C.board_clock_init()
	C.board_can_clock_pins_init()
	gen.boot() // hands off to ThreadX (tx_kernel_enter -> tx_application_define); never returns
}

// main is never called on target (crt0 enters at `entry`); V requires one in module main
fn main() {
	entry()
}
