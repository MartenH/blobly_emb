/* NUCLEO-H723ZG board bring-up (single Cortex-M7) — register-level, no HAL.
 *
 * Adapted from boards/h755zi/board.c (the closest Nucleo analog: 8 MHz HSE bypass from
 * the ST-LINK MCO, FDCAN1 on PD0/PD1). The two real differences:
 *  - Supply: the on-board LDO (the H723ZG Nucleo default), NOT the -Q's Direct SMPS.
 *    The clock chain is otherwise identical.
 *  - Single core: no CM4, no dual-core RCC/PWR sharing to worry about.
 *
 * The H723 can run to 550 MHz (VOS0); this ships the same safe 400 MHz VOS1 point as the
 * -Q board (PLL 8/2*200/2). BENCH-VERIFIED on a NUCLEO-H723ZG as system_full's zone_a
 * (2026-07-26): SYSCLK reached 400 MHz and FDCAN1 carried the edge bus. The waits are all
 * bounded regardless, so a rail that never readies falls back to HSI 64 MHz rather than hang.
 * FDCAN kernel clock stays HSE 8 MHz (see board.mk timing).
 */
#include <stm32h723xx.h>

/* Achieved CPU frequency in MHz (DWT cycles per microsecond). HSI reset value until
 * board_clock_init() confirms SYSCLK on PLL1, so board_now_us() stays correct on a
 * degraded bring-up. */
static volatile uint32_t g_cpu_mhz = 64;

/* board_clock_init: bring the M7 to 400 MHz. Chain: LDO supply -> VOS1 -> flash WS ->
 * PLL1 (8/2*200/2 = 400) -> switch SYSCLK. Every wait is BOUNDED (fall back to HSI). */
void board_clock_init(void) {
	uint32_t t;

	/* 1. Core supply = on-board LDO. The H723 is a value-line part with NO SMPS — its
	 *    PWR_CR3 has only LDOEN/BYPASS (no SMPS* bits exist to clear). Set LDOEN, clear
	 *    BYPASS. A supply write that mismatches the board browns out VCORE and locks the
	 *    debugger — recover with st-flash --connect-under-reset. */
	PWR->CR3 = (PWR->CR3 & ~PWR_CR3_BYPASS) | PWR_CR3_LDOEN;
	for (t = 0; (PWR->CSR1 & PWR_CSR1_ACTVOSRDY) == 0u; t++) {
		if (t >= 4000000u) return; /* supply not ready -> stay on HSI */
	}

	/* 2. HSE (8 MHz bypass from the ST-LINK MCO): PLL source + FDCAN kernel clock. */
	RCC->CR |= RCC_CR_HSEBYP | RCC_CR_HSEON;
	for (t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) return;
	}

	/* 3. VOS1 (400 MHz-capable VCORE). On the H72x/73x `D3CR |= VOS` (both bits) is the
	 *    top level; we drive PLL to 400 to stay at the proven -Q point. */
	PWR->D3CR |= PWR_D3CR_VOS;
	for (t = 0; (PWR->D3CR & PWR_D3CR_VOSRDY) == 0u; t++) {
		if (t >= 4000000u) return;
	}

	/* 4. Flash wait-states for 200 MHz AXI @ VOS1: 2 WS, WRHIGHFREQ = 0b10. */
	FLASH->ACR = FLASH_ACR_LATENCY_2WS | (0x2UL << FLASH_ACR_WRHIGHFREQ_Pos);

	/* 5. Bus prescalers: CPU /1 (400), AHB /2 (200), APB1/2/3/4 /2 (100 MHz). */
	RCC->D1CFGR = RCC_D1CFGR_D1CPRE_DIV1 | RCC_D1CFGR_HPRE_DIV2 | RCC_D1CFGR_D1PPRE_DIV2;
	RCC->D2CFGR = RCC_D2CFGR_D2PPRE1_DIV2 | RCC_D2CFGR_D2PPRE2_DIV2;
	RCC->D3CFGR = RCC_D3CFGR_D3PPRE_DIV2;

	/* 6. PLL1 from HSE: /2 = 4 MHz ref (RGE 4-8), x200 = 800 MHz VCO, /2 = 400 MHz.
	 *    Divider fields are written value-1. PLLSRC = HSE is 0b10 (=2). */
	RCC->PLLCKSELR = (2u << RCC_PLLCKSELR_DIVM1_Pos) | RCC_PLLCKSELR_PLLSRC_HSE;
	RCC->PLLCFGR = RCC_PLLCFGR_PLL1RGE_1 | RCC_PLLCFGR_DIVP1EN;
	RCC->PLL1DIVR = ((200u - 1u) << RCC_PLL1DIVR_N1_Pos) | ((2u - 1u) << RCC_PLL1DIVR_P1_Pos)
	              | ((2u - 1u) << RCC_PLL1DIVR_Q1_Pos) | ((2u - 1u) << RCC_PLL1DIVR_R1_Pos);
	RCC->CR |= RCC_CR_PLL1ON;
	for (t = 0; (RCC->CR & RCC_CR_PLL1RDY) == 0u; t++) {
		if (t >= 4000000u) return; /* PLL didn't lock -> stay on HSI */
	}

	/* 7. Switch SYSCLK to PLL1 (400 MHz). */
	RCC->CFGR = (RCC->CFGR & ~RCC_CFGR_SW) | RCC_CFGR_SW_PLL1;
	for (t = 0; (RCC->CFGR & RCC_CFGR_SWS) != RCC_CFGR_SWS_PLL1; t++) {
		if (t >= 4000000u) return;
	}
	g_cpu_mhz = 400; /* SYSCLK confirmed on PLL1 -> DWT ticks at 400 MHz */

	/* 8. Instruction cache — non-negotiable (the flash-fetch alignment lottery, see
	 *    boards/h735dk/board.c). D-cache stays off: nothing DMAs on these nodes. */
	SCB_EnableICache();
}

/* board_timebase_init: start the free-running 32-bit DWT cycle counter. */
void board_timebase_init(void) {
	CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
	DWT->CYCCNT = 0u;
	DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

/* board_now_us: monotonic microseconds. 32-bit CYCCNT wraps every ~10.7 s at 400 MHz;
 * deltas accumulate into a 64-bit counter. PRIMASK guard: threads + ISRs call this. */
uint64_t board_now_us(void) {
	static uint32_t last = 0u;
	static uint64_t acc_cycles = 0u;
	uint32_t prim;
	__asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");
	uint32_t now = DWT->CYCCNT;
	acc_cycles += (uint32_t)(now - last);
	last = now;
	uint64_t r = acc_cycles / g_cpu_mhz;
	__asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");
	return r;
}

/* FDCAN1 kernel clock (HSE) + APB clock + PD0 (RX) / PD1 (TX) AF9 — identical to the
 * -Q Nucleo (both route FDCAN1 to the Zio CN9 PD0/PD1 pair). */
void board_can_clock_pins_init(void) {
	RCC->CR |= RCC_CR_HSEBYP;
	RCC->CR |= RCC_CR_HSEON;
	/* BOUNDED, like board_clock_init's HSE wait: if HSE never readies, return rather than hang
	 * the whole ECU here (board_clock_init already fell back to HSI, and the comm thread's
	 * can Channel.open() will park just that thread on the mistimed bus). */
	for (uint32_t t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) return;
	}
	RCC->D2CCIP1R &= ~RCC_D2CCIP1R_FDCANSEL; /* 00 -> HSE (8 MHz) */

	RCC->APB1HENR |= RCC_APB1HENR_FDCANEN;

	RCC->AHB4ENR |= RCC_AHB4ENR_GPIODEN;
	(void)RCC->AHB4ENR;
	GPIOD->MODER &= ~((3u << (0u * 2u)) | (3u << (1u * 2u)));
	GPIOD->MODER |= ((2u << (0u * 2u)) | (2u << (1u * 2u)));
	GPIOD->OSPEEDR |= (3u << (0u * 2u)) | (3u << (1u * 2u));
	GPIOD->AFR[0] &= ~((0xFu << (0u * 4u)) | (0xFu << (1u * 4u)));
	GPIOD->AFR[0] |= ((9u << (0u * 4u)) | (9u << (1u * 4u)));
}

/* Pads this board already owns (board.h, docs/io.md "pins are exclusive"). */
int board_io_pin_reserved(int port, int pin) {
	if (port == 3 && (pin == 0 || pin == 1)) return 1;   /* PD0/PD1: FDCAN1 RX/TX */
	if (port == 0 && (pin == 13 || pin == 14)) return 1; /* PA13/PA14: SWD */
	if (port == 1 && pin == 3) return 1;                 /* PB3: SWO */
	return 0;
}

/* Weak default for the shared ETH interrupt vector (boards/common/vectors.S IRQ61):
 * this node has no ETH driver, so absorb the vector's .word so the common table links. */
__attribute__((weak)) void ETH_IRQHandler(void) {
}
