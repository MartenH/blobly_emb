/* STM32H735G-DK HyperRAM bring-up — register-level, no HAL.
 *
 * Pins and HyperBus timing follow ST's stm32h735g-dk BSP (stm32h735g_discovery_ospi.c) and its
 * S70KL1281 component. One deliberate difference: the BSP clocks OCTOSPI from PLL2_R, but PLL2
 * is this board's FDCAN kernel clock (board.c), so the kernel clock here is HCLK3 = 275 MHz,
 * divided by 3 = 91.7 MHz (the part is rated to 100 MHz at 3 V). The memory keeps its power-on
 * configuration register (6-clock fixed latency), which is what the BSP programs anyway.
 */
#include <stm32h735xx.h>
#include "board.h"
#include "hyperram.h"

#define OSPI_PRESCALER 3u  /* 275 / 3 = 91.7 MHz */
#define OSPI_TACC      6u  /* initial latency, clocks (device default) */
#define OSPI_TRWR      4u  /* read-write recovery: 40 ns = 3.7 clocks at 91.7 MHz */
#define OSPI_REFRESH   360u /* max CS low 4 us = 366 clocks */

static void pin_ospi(GPIO_TypeDef *g, uint32_t pin, uint32_t af) {
	g->MODER = (g->MODER & ~(3u << (pin * 2u))) | (2u << (pin * 2u));
	g->OTYPER &= ~(1u << pin);
	g->OSPEEDR |= 3u << (pin * 2u);
	g->PUPDR &= ~(3u << (pin * 2u));
	g->AFR[pin >> 3] = (g->AFR[pin >> 3] & ~(0xFu << ((pin & 7u) * 4u))) | (af << ((pin & 7u) * 4u));
}

int hyperram_init(void) {
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOFEN | RCC_AHB4ENR_GPIOGEN;
	(void)RCC->AHB4ENR;
	/* OCTOSPIM port 2: NCS PG12 (AF3), CLK PF4, DQS PF12, IO0..3 PF0..3, IO4/5 PG0/1, IO6 PG10
	 * (AF3), IO7 PG11 — AF9 unless noted */
	pin_ospi(GPIOG, 12u, 3u);
	pin_ospi(GPIOF, 4u, 9u);
	pin_ospi(GPIOF, 12u, 9u);
	for (uint32_t p = 0; p < 4u; p++) pin_ospi(GPIOF, p, 9u);
	pin_ospi(GPIOG, 0u, 9u);
	pin_ospi(GPIOG, 1u, 9u);
	pin_ospi(GPIOG, 10u, 3u);
	pin_ospi(GPIOG, 11u, 9u);

	/* kernel clock HCLK3 (OCTOSPISEL = 00, the reset value); OCTOSPIM's port 2 is wired to
	 * OCTOSPI2 at reset, so the IO manager only needs its clock */
	RCC->D1CCIPR &= ~(3u << RCC_D1CCIPR_OCTOSPISEL_Pos);
	RCC->AHB3ENR |= RCC_AHB3ENR_OSPI2EN | RCC_AHB3ENR_IOMNGREN;
	(void)RCC->AHB3ENR;
	RCC->AHB3RSTR |= RCC_AHB3RSTR_OSPI2RST;
	RCC->AHB3RSTR &= ~RCC_AHB3RSTR_OSPI2RST;

	OCTOSPI2->CR = 0u;
	OCTOSPI2->DCR1 = (4u << OCTOSPI_DCR1_MTYP_Pos)          /* HyperBus memory */
	               | (23u << OCTOSPI_DCR1_DEVSIZE_Pos)      /* 2^24 bytes */
	               | ((4u - 1u) << OCTOSPI_DCR1_CSHT_Pos);   /* delay block in the path, as the BSP */
	OCTOSPI2->DCR2 = (OSPI_PRESCALER - 1u) << OCTOSPI_DCR2_PRESCALER_Pos;
	OCTOSPI2->DCR3 = 23u << OCTOSPI_DCR3_CSBOUND_Pos;        /* one 8 MB die per CS assertion */
	OCTOSPI2->DCR4 = OSPI_REFRESH << OCTOSPI_DCR4_REFRESH_Pos;
	OCTOSPI2->TCR = 1u << OCTOSPI_TCR_DHQC_Pos;               /* delay hold a quarter cycle */
	OCTOSPI2->HLCR = (OSPI_TRWR << OCTOSPI_HLCR_TRWR_Pos) | (OSPI_TACC << OCTOSPI_HLCR_TACC_Pos)
	               | (1u << OCTOSPI_HLCR_LM_Pos);             /* fixed latency, latency on write */
	/* the HyperBus transaction format: 8-line DTR address (32 bit) and data, DQS for reads */
	const uint32_t ccr = (1u << OCTOSPI_CCR_DQSE_Pos) | (1u << OCTOSPI_CCR_DDTR_Pos) | (4u << OCTOSPI_CCR_DMODE_Pos)
	                   | (3u << OCTOSPI_CCR_ADSIZE_Pos) | (1u << OCTOSPI_CCR_ADDTR_Pos) | (4u << OCTOSPI_CCR_ADMODE_Pos);
	OCTOSPI2->CCR = ccr;
	OCTOSPI2->WCCR = ccr;
	OCTOSPI2->CR = (3u << OCTOSPI_CR_FMODE_Pos) | ((4u - 1u) << OCTOSPI_CR_FTHRES_Pos) | (1u << OCTOSPI_CR_EN_Pos);

	/* an address-dependent pattern over both ends of the part (both dies) */
	volatile uint32_t *m = (volatile uint32_t *)HYPERRAM_BASE;
	const uint32_t words = 0x10000u / 4u, last = HYPERRAM_SIZE / 4u - words;
	for (uint32_t i = 0; i < words; i++) {
		m[i] = 0xA5A50000u ^ (i * 2654435761u);
		m[last + i] = 0x5A5A0000u ^ (i * 2246822519u);
	}
	for (uint32_t i = 0; i < words; i++) {
		if (m[i] != (0xA5A50000u ^ (i * 2654435761u))) return -1;
		if (m[last + i] != (0x5A5A0000u ^ (i * 2246822519u))) return -1;
	}
	return 0;
}
