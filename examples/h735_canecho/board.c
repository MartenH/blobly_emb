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

/* board_clock_init: bring the Cortex-M7 to its full 550 MHz. Reset default is HSI
 * 64 MHz (~1/8.6 speed). Chain: pick the board's core-supply mode (the H735-DK is
 * Direct SMPS) -> VOS0 (highest VCORE) -> flash wait-states -> PLL1 (25/5*220/2 =
 * 550 MHz) -> switch SYSCLK. Every wait is BOUNDED: if a rail never readies, we
 * return with SYSCLK still on the safe HSI (64 MHz) rather than hang. FDCAN is
 * unaffected — its kernel clock stays HSE 25 MHz (FDCANSEL), independent of SYSCLK.
 *
 * The supply write MUST match the board wiring (SB2/13/20/21 = Direct SMPS on this
 * DK); a mismatch browns out VCORE and locks the debugger — recover with
 * st-flash --connect-under-reset. */
void board_clock_init(void) {
	uint32_t t;

	/* 1. Core supply = Direct SMPS (SMPSEN on, LDO/bypass off) — matches the DK. */
	PWR->CR3 = (PWR->CR3 & ~(PWR_CR3_SMPSLEVEL | PWR_CR3_SMPSEXTHP | PWR_CR3_LDOEN | PWR_CR3_BYPASS))
	         | PWR_CR3_SMPSEN;
	for (t = 0; (PWR->CSR1 & PWR_CSR1_ACTVOSRDY) == 0u; t++) {
		if (t >= 4000000u) return; /* supply not ready -> stay on HSI */
	}

	/* 2. HSE (25 MHz bypass): PLL source (also the FDCAN kernel clock). */
	RCC->CR |= RCC_CR_HSEBYP | RCC_CR_HSEON;
	for (t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) return;
	}

	/* 3. VOS0 (highest VCORE) — required for 550 MHz. */
	PWR->D3CR |= PWR_D3CR_VOS;
	for (t = 0; (PWR->D3CR & PWR_D3CR_VOSRDY) == 0u; t++) {
		if (t >= 4000000u) return; /* VOS0 not reached -> stay on HSI */
	}

	/* 4. Flash wait-states for 275 MHz AXI @ VOS0: 3 WS, WRHIGHFREQ = 0b10. */
	FLASH->ACR = FLASH_ACR_LATENCY_3WS | (0x2UL << FLASH_ACR_WRHIGHFREQ_Pos);

	/* 5. Bus prescalers: CPU /1 (550), AHB /2 (275), APB1/2/3/4 /2 (137.5 MHz). */
	RCC->D1CFGR = RCC_D1CFGR_D1CPRE_DIV1 | RCC_D1CFGR_HPRE_DIV2 | RCC_D1CFGR_D1PPRE_DIV2;
	RCC->D2CFGR = RCC_D2CFGR_D2PPRE1_DIV2 | RCC_D2CFGR_D2PPRE2_DIV2;
	RCC->D3CFGR = RCC_D3CFGR_D3PPRE_DIV2;

	/* 6. PLL1 from HSE: /5 = 5 MHz ref, x220 = 1100 MHz VCO (wide), /2 = 550 MHz.
	 *    Divider fields are written value-1. */
	RCC->PLLCKSELR = (5u << RCC_PLLCKSELR_DIVM1_Pos) | (2u << RCC_PLLCKSELR_PLLSRC_Pos);
	RCC->PLLCFGR = RCC_PLLCFGR_PLL1RGE_1 | RCC_PLLCFGR_DIVP1EN;
	RCC->PLL1DIVR = ((220u - 1u) << RCC_PLL1DIVR_N1_Pos) | ((2u - 1u) << RCC_PLL1DIVR_P1_Pos)
	              | ((2u - 1u) << RCC_PLL1DIVR_Q1_Pos) | ((2u - 1u) << RCC_PLL1DIVR_R1_Pos);
	RCC->CR |= RCC_CR_PLL1ON;
	for (t = 0; (RCC->CR & RCC_CR_PLL1RDY) == 0u; t++) {
		if (t >= 4000000u) return; /* PLL didn't lock -> stay on HSI */
	}

	/* 7. Switch SYSCLK to PLL1 (550 MHz). */
	RCC->CFGR = (RCC->CFGR & ~RCC_CFGR_SW) | RCC_CFGR_SW_PLL1;
	for (t = 0; (RCC->CFGR & RCC_CFGR_SWS) != RCC_CFGR_SWS_PLL1; t++) {
		if (t >= 4000000u) return;
	}
}

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
