#ifndef BOARD_H
#define BOARD_H
#include <stdint.h>

/* Board primitives the V superloop (main.v) calls. Forced-included into the V
 * output so the compiler sees real prototypes (see Makefile -include). */
void board_init(void);
void board_led_toggle(void);
void board_delay_ms(uint32_t ms);

#endif
