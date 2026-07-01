#ifndef BLOBLY_H755_CANFD_BOARD_H
#define BLOBLY_H755_CANFD_BOARD_H

/* One-time bring-up for both FDCAN buses (kernel clock + APB clock + PD1/PD0 and
 * PB6/PB12 AF9), called from main.v before can.Channel.open(). See board.c. */
void board_can_clock_pins_init(void);

#endif
