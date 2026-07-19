module main

// h735_io_lamp entry. The generated gen/loom_gen.v provides run() (the FB
// superloop), the comm thread (bus owner), the platform io thread, and
// @[export] tx_application_define — which runs io cfg/init at the top, before
// any thread exists (REQ-IO-009). This hand-written, platform-aware main does
// only the board bring-up then hands control to the ThreadX kernel. crt0.S
// calls main__main (V's `fn main` body).
import gen

fn C.board_clock_init()          // 550 MHz PLL1 (boards/h735dk/board.c)
fn C.board_can_clock_pins_init() // FDCAN1 kernel clock + PH13/PH14 AF9

fn main() {
	C.board_clock_init()
	C.board_can_clock_pins_init()
	gen.boot() // hands off to ThreadX (tx_kernel_enter -> tx_application_define); never returns
}
