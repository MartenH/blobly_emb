#ifndef BLOBLY_H723_CANECHO_BOARD_H
#define BLOBLY_H723_CANECHO_BOARD_H

/* One-time FDCAN bring-up (kernel clock + APB clock + PD1/PD0 and PB6/PB12 AF9),
 * called from main.v before can.Channel.open(). See board.c. */
void board_can_clock_pins_init(void);

#endif
