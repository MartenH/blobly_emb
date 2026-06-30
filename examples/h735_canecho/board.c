/* STM32H735G-DK board bring-up for FDCAN1 — register-level, no HAL.
 *
 * The register-level M_CAN driver (driver/can/can_fdcan.c) configures the CAN
 * core but expects the board to set up everything *around* it first:
 *   1. a kernel clock for the CAN bit-timing  (we use HSE 25 MHz directly),
 *   2. the peripheral's APB bus clock,
 *   3. the TX/RX pins muxed to their alternate function.
 * main.v calls board_can_clock_pins_init() once before can.Channel.open().
 *
 * FDCAN1 on this Discovery kit: PH13 = FDCAN1_TX, PH14 = FDCAN1_RX (AF9), wired
 * to the onboard 3.3 V CAN-FD transceiver (FDCAN1/2 are not behind the CAN solder
 * bridges — only FDCAN3 is). HSE is X1, a 25 MHz *oscillator* (NZ2520SH), not a
 * passive crystal — so HSE runs in BYPASS mode (HSEBYP), else HSERDY never sets.
 *
 * 25 MHz / 500 kbit needs 10 tq/bit (NBRP 5); the Makefile passes the matching
 * BLOB_FDCAN_KCLK_HZ / TQ / TSEGx so the driver computes an integer prescaler.
 */
#include <stm32h735xx.h>

void board_can_clock_pins_init(void) {
	/* 1. HSE in bypass mode (X1 is an oscillator, not a crystal), on, then select
	 *    it as the FDCAN kernel clock (FDCANSEL = 00 = HSE). HSEBYP must be set
	 *    while HSE is off — it is at reset. */
	RCC->CR |= RCC_CR_HSEBYP;
	RCC->CR |= RCC_CR_HSEON;
	while ((RCC->CR & RCC_CR_HSERDY) == 0u) {
	}
	RCC->D2CCIP1R &= ~RCC_D2CCIP1R_FDCANSEL; /* 00 -> HSE (25 MHz) */

	/* 2. FDCAN peripheral (APB1H) clock, for register access. */
	RCC->APB1HENR |= RCC_APB1HENR_FDCANEN;

	/* 3. GPIOH clock, then mux PH13/PH14 to AF9 (FDCAN1_TX/RX). */
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOHEN;
	(void)RCC->AHB4ENR; /* read-back: let the clock settle before touching GPIOH */

	/* MODER: PH13, PH14 -> alternate function (0b10). */
	GPIOH->MODER &= ~((3u << (13u * 2u)) | (3u << (14u * 2u)));
	GPIOH->MODER |= ((2u << (13u * 2u)) | (2u << (14u * 2u)));

	/* OSPEEDR: very high speed (clean CAN edges). */
	GPIOH->OSPEEDR |= (3u << (13u * 2u)) | (3u << (14u * 2u));

	/* AFR[1] holds the AF nibble for pins 8..15; nibble (pin-8). AF9 = FDCAN1. */
	GPIOH->AFR[1] &= ~((0xFu << ((13u - 8u) * 4u)) | (0xFu << ((14u - 8u) * 4u)));
	GPIOH->AFR[1] |= ((9u << ((13u - 8u) * 4u)) | (9u << ((14u - 8u) * 4u)));
}
