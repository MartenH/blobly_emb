/* STM32H735G-DK board bring-up for the h735_app showcase — register-level, no HAL.
 *
 * Same FDCAN1 bring-up as h735_canecho, plus a bare-metal timebase: the Loom and the
 * telemetry loop need a monotonic microsecond clock (host/sim gets it from POSIX
 * clock_gettime; on target there is none), so we run the Cortex-M7 DWT cycle counter
 * and divide by the achieved CPU MHz.
 *
 * FDCAN1: PH13 = FDCAN1_TX, PH14 = FDCAN1_RX (AF9), to the onboard 3.3 V CAN-FD
 * transceiver. HSE is X1, a 25 MHz *oscillator* (NZ2520SH), so it runs in BYPASS.
 */
#include <stm32h735xx.h>

/* Achieved CPU frequency in MHz, i.e. DWT cycles per microsecond. Starts at the HSI
 * reset value; board_clock_init() bumps it to 550 only once SYSCLK is confirmed on
 * PLL1, so board_now_us() stays correct even if the clock bring-up falls back. */
static volatile uint32_t g_cpu_mhz = 64;

/* board_clock_init: bring the Cortex-M7 to its full 550 MHz. Chain: Direct-SMPS
 * supply -> VOS0 -> flash wait-states -> PLL1 (25/5*220/2 = 550 MHz) -> switch
 * SYSCLK. Every wait is BOUNDED: if a rail never readies we return with SYSCLK still
 * on the safe HSI (64 MHz). FDCAN is unaffected — its kernel clock stays HSE 25 MHz.
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
	 *    Divider fields are written value-1. PLLSRC = HSE is 0b10 (=2); the symbolic
	 *    constant makes that explicit (0=HSI, 1=CSI, 2=HSE, 3=none). */
	RCC->PLLCKSELR = (5u << RCC_PLLCKSELR_DIVM1_Pos) | RCC_PLLCKSELR_PLLSRC_HSE;
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
	g_cpu_mhz = 550; /* SYSCLK confirmed on PLL1 -> DWT ticks at 550 MHz */

	/* 8. Instruction cache. Without it the M7 fetches every instruction from 3-WS flash
	 * and a tight loop's throughput depends on where its fetch boundaries happen to land
	 * — a code-size change ANYWHERE re-rolls that dice (observed on this bench: the same
	 * LCG loop swung 18k..183k iters/ms between otherwise-identical images, and one
	 * 9-line shell commit tipped the load demo from 43% into permanent overrun). The
	 * D-cache stays off on purpose: nothing here DMAs, but cache-coherency bugs are a
	 * class we don't need today, and the I-cache alone removes the fetch lottery. */
	SCB_EnableICache();
}

/* board_timebase_init: start the DWT cycle counter (free-running, 32-bit). It
 * increments at the CPU clock, so it doubles as the load-measurement clock. */
void board_timebase_init(void) {
	CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk; /* enable the trace/debug block */
	DWT->CYCCNT = 0u;
	DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

/* board_now_us: monotonic microseconds since board_timebase_init(). The 32-bit
 * CYCCNT wraps every ~7.8 s at 550 MHz; we accumulate deltas into a 64-bit counter so
 * the returned value never wraps as long as this is called at least that often (the
 * super-loop calls it every pass — far more often).
 *
 * The last/acc_cycles statics are shared: on the ThreadX target BOTH the FB thread and the
 * bus-owning comm thread call this (and an ISR could preempt mid-update). A brief PRIMASK
 * critical section serialises the read-modify-write so the delta can't be applied twice or
 * out of order (which would corrupt the load cadence + every trace/telemetry timestamp). */
uint64_t board_now_us(void) {
	static uint32_t last = 0u;
	static uint64_t acc_cycles = 0u;
	uint32_t prim;
	__asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");
	uint32_t now = DWT->CYCCNT;
	acc_cycles += (uint32_t)(now - last); /* modular 32-bit delta handles wrap */
	last = now;
	uint64_t r = acc_cycles / g_cpu_mhz;
	__asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");
	return r;
}

void board_can_clock_pins_init(void) {
	/* 1. HSE in bypass mode (X1 is an oscillator, not a crystal), on, then select
	 *    it as the FDCAN kernel clock (FDCANSEL = 00 = HSE). HSEBYP must be set
	 *    while HSE is off — it is at reset (or already set by board_clock_init). */
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

	/* AFR[1] holds the AF nibble for pins 8..15. AF9 = FDCAN1. */
	GPIOH->AFR[1] &= ~((0xFu << ((13u - 8u) * 4u)) | (0xFu << ((14u - 8u) * 4u)));
	GPIOH->AFR[1] |= ((9u << ((13u - 8u) * 4u)) | (9u << ((14u - 8u) * 4u)));
}
