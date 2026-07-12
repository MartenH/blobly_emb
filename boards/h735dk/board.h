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

#endif
