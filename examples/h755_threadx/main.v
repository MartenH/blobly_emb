module main

// h735_threadx entry (P3c-1 phase 6a). The generated gen/loom_gen.v provides run() (the FB
// superloop), the ThreadX app thread, and @[export] tx_application_define. This hand-written,
// platform-aware main does only the board bring-up then hands control to the ThreadX kernel:
// tx_kernel_enter() calls tx_application_define, which creates the app_main thread. crt0.S
// calls main__main (V's `fn main` body), bypassing V's hosted main wrapper.
import gen

fn C.board_clock_init()          // PLL1 to the board's max (boards/<b>/board.c)
fn C.board_can_clock_pins_init() // FDCAN1 kernel clock + PD0/PD1 AF9

fn main() {
	C.board_clock_init()
	C.board_can_clock_pins_init()
	// gen.boot() releases the parked CM4 (C.xcore_clocks_ready) itself now — the generator emits it
	// for any satellite-owner, so a shared main.v (system_full) gets it too (codex #235).
	gen.boot() // hands off to ThreadX (tx_kernel_enter -> tx_application_define); never returns
}
