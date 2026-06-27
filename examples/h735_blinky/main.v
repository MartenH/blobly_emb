module main

// Bare-metal blinky for the STM32H735G-DK — the smallest thing that proves the
// pipeline: V -freestanding -> C -> arm-none-eabi-gcc -> .elf/.bin, flashed and
// running on real silicon. No HAL, no CMSIS, no Cube — the few registers we
// touch are poked directly in board.c.
//
// The superloop is V; the three primitives below are tiny C shims (board.c).
// Once this blinks, driver/can's bare-metal FDCAN backend drops in next.

fn C.board_init()
fn C.board_led_toggle()
fn C.board_delay_ms(ms u32)

fn main() {
	C.board_init()
	for {
		C.board_led_toggle()
		C.board_delay_ms(500)
	}
}
