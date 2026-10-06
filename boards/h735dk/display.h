/* The H735-DK display: one ThreadX thread that owns the LCD, the touch panel and LVGL.
 *
 * A node with [display] in its ecu.toml gets this thread from the generated
 * tx_application_define (display_thread_create, at a priority below every other thread) and
 * provides the screen itself — two functions, called only from the display thread:
 *   ui_create()  build the screen once, after LVGL is up
 *   ui_update()  refresh it from whatever the node publishes; called every pass (<= 20 ms)
 * Nothing else may call LVGL.
 */
#ifndef BOARD_DISPLAY_H
#define BOARD_DISPLAY_H
#include <stdint.h>

void display_thread_create(unsigned int priority);

void ui_create(void);
void ui_update(void);

/* what the display thread reports about itself (read from any thread, written by it alone) */
enum { DISPLAY_STARTING = 0, DISPLAY_RUNNING = 1, DISPLAY_NO_RAM = -1 };
extern volatile int display_state;      /* DISPLAY_NO_RAM: the HyperRAM failed its test, panel off */
extern volatile uint32_t display_load_pm; /* the thread's CPU, per mille of the last second */
extern volatile uint32_t display_fps;     /* frames shown in the last second */
extern volatile uint32_t display_cpu_pm;  /* the whole core's load, per mille of the last second
                                           * (every thread and ISR: measured by an idle thread at
                                           * priority 31, display.c) */
extern volatile int display_touch_chip;   /* TOUCH_* (touch.h) */

#endif
