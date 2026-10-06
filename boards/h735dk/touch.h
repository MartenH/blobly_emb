/* STM32H735G-DK capacitive touch on I2C4 (PF14 SCL / PF15 SDA): a GT911 on later board
 * revisions, an FT5336 on earlier ones — probed in that order, as ST's BSP does. Polled. */
#ifndef BOARD_TOUCH_H
#define BOARD_TOUCH_H

enum { TOUCH_NONE = 0, TOUCH_GT911 = 1, TOUCH_FT5336 = 2 };

/* touch_init: I2C4 up, controller probed; returns TOUCH_NONE when nothing answers. */
int touch_init(void);

/* touch_read: 1 while a finger is down, with its position in panel pixels; 0 otherwise.
 * raw_x/raw_y keep the controller's own coordinates of the last contact (for calibration). */
int touch_read(int *x, int *y);
extern volatile int touch_raw_x, touch_raw_y;

#endif
