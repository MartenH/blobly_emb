/* STM32H735G-DK board primitives — register-level, no HAL/CMSIS.
 *
 * User LEDs (UM2679): LD1 (green) = PC2, LD2 (red) = PC3, both on GPIOC.
 * Clock: the MCU runs on HSI ~64 MHz out of reset; we don't touch the PLL, so
 * board_delay_ms() is a calibrated busy-wait (approximate — fine for a blink).
 *
 * STM32H7 registers (RM0468): GPIO ports live on the AHB4 bus.
 */
#include "board.h"
#include <stdint.h>

#define REG(addr) (*(volatile uint32_t *)(addr))

#define RCC_AHB4ENR REG(0x580244E0u) /* RCC base 0x58024400 + 0xE0; GPIOCEN = bit 2 */
#define GPIOC_MODER REG(0x58020800u) /* GPIOC base + 0x00 */
#define GPIOC_ODR   REG(0x58020814u) /* GPIOC base + 0x14 */

#define LD1_PIN 2u /* green */
#define LD2_PIN 3u /* red   */

void board_init(void) {
	RCC_AHB4ENR |= (1u << 2);                 /* enable GPIOC clock */
	(void)RCC_AHB4ENR;                        /* sync after RCC enable */

	/* MODER: 2 bits/pin, 01 = general-purpose output */
	GPIOC_MODER &= ~((3u << (LD1_PIN * 2)) | (3u << (LD2_PIN * 2)));
	GPIOC_MODER |= ((1u << (LD1_PIN * 2)) | (1u << (LD2_PIN * 2)));
}

void board_led_toggle(void) {
	GPIOC_ODR ^= (1u << LD1_PIN) | (1u << LD2_PIN);
}

void board_delay_ms(uint32_t ms) {
	/* ~HSI 64 MHz; the loop is a few cycles — tune the multiplier to taste. */
	for (volatile uint32_t i = 0; i < ms * 8000u; i++) {
		__asm__ volatile("nop");
	}
}
