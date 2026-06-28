#ifndef BLOBLY_H735_CANECHO_BOARD_H
#define BLOBLY_H735_CANECHO_BOARD_H

/* One-time FDCAN1 bring-up (clock source + APB clock + PH13/PH14 AF9), called
 * from main.v before can.Channel.open(). Implemented in board.c. */
void board_can_clock_pins_init(void);

#endif
