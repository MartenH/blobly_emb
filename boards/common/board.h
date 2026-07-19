#ifndef BLOBLY_H735_APP_BOARD_H
#define BLOBLY_H735_APP_BOARD_H

#include <stdint.h>

/* Raise the M7 to 550 MHz (Direct-SMPS supply -> VOS0 -> PLL1). Call first. */
void board_clock_init(void);

/* Start the DWT cycle counter; board_now_us() reads it. Call after the clock init. */
void board_timebase_init(void);

/* Monotonic microseconds since board_timebase_init(). */
uint64_t board_now_us(void);

/* FDCAN1 bring-up: HSE kernel clock + APB clock + PH13/PH14 AF9. */
void board_can_clock_pins_init(void);

/* Platform pin-ownership table (docs/io.md "pins are exclusive"): 1 if the board
 * already owns PA..PK[port]/pin (CAN, SWD/SWO, ETH PHY, ...) — an io point on such
 * a pad is rejected at cfg. Weak default (io_stm32.c) reserves nothing; each
 * board.c overrides with its real table — only the board knows its silicon. */
int board_io_pin_reserved(int port, int pin);

#endif
