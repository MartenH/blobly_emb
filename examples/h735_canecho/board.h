#ifndef BLOBLY_H735_CANECHO_BOARD_H
#define BLOBLY_H735_CANECHO_BOARD_H

/* One-time FDCAN1 bring-up (clock source + APB clock + PH13/PH14 AF9), called
 * from main.v before can.Channel.open(). Implemented in board.c. */
/* Raise the M7 to 550 MHz (Direct-SMPS supply -> VOS0 -> PLL1). Call first. */
void board_clock_init(void);

void board_can_clock_pins_init(void);

#endif
