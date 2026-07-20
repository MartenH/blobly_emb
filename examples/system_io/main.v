module main

// h755_io entry. The generated gen/loom_gen.v provides run() (the FB superloop), the
// io thread, and @[export] tx_application_define — which runs io cfg/init + the boot
// publish BEFORE any thread exists (REQ-IO-009), then creates the app + io threads.
// This hand-written, platform-aware main does only the board bring-up then hands
// control to the ThreadX kernel. crt0.S calls main__main (V's `fn main` body).
import gen

fn C.board_clock_init()          // PLL1 to the board's max (boards/h755zi/board.c)
fn C.board_can_clock_pins_init() // FDCAN1 kernel clock + PD0/PD1 AF9

fn main() {
	C.board_clock_init()
	C.board_can_clock_pins_init()
	gen.boot() // hands off to ThreadX (tx_kernel_enter -> tx_application_define); never returns
}
