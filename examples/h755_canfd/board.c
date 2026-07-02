/* STM32H755 (Nucleo-H755ZI-Q) two-bus FDCAN bring-up — register-level, no HAL.
 *
 * The register-level M_CAN driver (driver/can/can_fdcan.c) configures each CAN
 * core; this sets up everything around them: the kernel clock, the peripheral
 * clock, and the TX/RX pin mux. main.v calls board_can_clock_pins_init() once.
 *
 *   FDCAN1: PD1 = TX, PD0 = RX (AF9)
 *   FDCAN2: PB6 = TX, PB12 = RX (AF9)
 *
 * Kernel clock = HSE. On the Nucleo-H755ZI-Q, HSE is an 8 MHz clock from the
 * ST-LINK MCO in BYPASS mode (the default solder-bridge config) — so HSEBYP is
 * set. 8 MHz / 500 kbit = exactly 16 tq (BRP 1), which is the driver's default,
 * so NO bit-timing override is needed (unlike the H735's 25 MHz). If your board
 * instead has the 25 MHz X3 crystal fitted, drop HSEBYP and pass
 * BLOB_FDCAN_KCLK_HZ=25000000 + the tseg override, as h735_canecho does.
 */
#include <stm32h7xx.h> /* family dispatcher; build sets -DSTM32H755xx -DCORE_CM7 */

void board_can_clock_pins_init(void) {
	/* 1. HSE (8 MHz, bypass) on, then select as the FDCAN kernel clock (00 = HSE). */
	RCC->CR |= RCC_CR_HSEBYP;
	RCC->CR |= RCC_CR_HSEON;
	while ((RCC->CR & RCC_CR_HSERDY) == 0u) {
	}
	RCC->D2CCIP1R &= ~RCC_D2CCIP1R_FDCANSEL;

	/* 2. FDCAN peripheral (APB1H) clock. */
	RCC->APB1HENR |= RCC_APB1HENR_FDCANEN;

	/* 3a. FDCAN1: PD1 = TX, PD0 = RX, AF9 (both in AFR[0]). */
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIODEN;
	(void)RCC->AHB4ENR; /* read-back: let the clock settle before touching GPIOD */
	GPIOD->MODER &= ~((3u << (0u * 2u)) | (3u << (1u * 2u)));
	GPIOD->MODER |= ((2u << (0u * 2u)) | (2u << (1u * 2u))); /* alternate function */
	GPIOD->OSPEEDR |= (3u << (0u * 2u)) | (3u << (1u * 2u));
	GPIOD->AFR[0] &= ~((0xFu << (0u * 4u)) | (0xFu << (1u * 4u)));
	GPIOD->AFR[0] |= ((9u << (0u * 4u)) | (9u << (1u * 4u)));

	/* 3b. FDCAN2: PB6 = TX (AFR[0] nibble 6), PB12 = RX (AFR[1] nibble 4), AF9. */
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOBEN;
	(void)RCC->AHB4ENR;
	GPIOB->MODER &= ~((3u << (6u * 2u)) | (3u << (12u * 2u)));
	GPIOB->MODER |= ((2u << (6u * 2u)) | (2u << (12u * 2u)));
	GPIOB->OSPEEDR |= (3u << (6u * 2u)) | (3u << (12u * 2u));
	GPIOB->AFR[0] &= ~(0xFu << (6u * 4u));
	GPIOB->AFR[0] |= (9u << (6u * 4u));
	GPIOB->AFR[1] &= ~(0xFu << ((12u - 8u) * 4u));
	GPIOB->AFR[1] |= (9u << ((12u - 8u) * 4u));
}
