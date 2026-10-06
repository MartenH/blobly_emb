/* STM32H735G-DK 4.3" RK043FN48H panel (480x272) on the LTDC — register-level, no HAL. */
#ifndef BOARD_LCD_H
#define BOARD_LCD_H
#include <stdint.h>

#define LCD_W 480
#define LCD_H 272

/* lcd_init: pixel clock (PLL3_R), pins, LTDC timing and layer 1 on `fb` (LCD_W x LCD_H RGB565 in
 * memory the LTDC can master — not the DTCM), panel on. Waits 40 ms for the panel's power-up with
 * the CPU, so call it from the thread that will draw. */
void lcd_init(const void *fb);

/* lcd_show: scan out `fb` (LCD_W x LCD_H RGB565, LTDC-reachable) from the next vertical
 * blanking on; lcd_shown() is 1 once that switch has happened. Double buffering's swap. */
void lcd_show(const void *fb);
int lcd_shown(void);

#endif
