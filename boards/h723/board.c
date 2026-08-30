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
 * bounded regardless, so a rail that never readies HANGS (board_clock_fault) rather than run
 * on a degraded clock. FDCAN kernel clock stays HSE 8 MHz (see board.mk timing).
 */
#include <stm32h723xx.h>

/* Achieved CPU frequency in MHz (DWT cycles per microsecond). HSI reset value until
 * board_clock_init() confirms SYSCLK on PLL1 (and hangs otherwise), so board_now_us() only
 * ever runs at the rated clock. */
static volatile uint32_t g_cpu_mhz = 64;

/* board_clock_fault — a clock we can't bring up is a HARD FAULT, not a limp (an ECU on the
 * wrong clock violates its real-time timing, and the FDCAN kernel clock rides the same HSE).
 * Hang deterministically; SWD reads the PC + the RCC/PWR registers to see which rail failed.
 * Unreachable on healthy silicon. Same policy as boards/h755zi. */
static void __attribute__((noreturn)) board_clock_fault(void) {
	for (;;) {
	}
}

/* board_clock_init: bring the M7 to 400 MHz. Chain: LDO supply -> VOS1 -> flash WS ->
 * PLL1 (8/2*200/2 = 400) -> switch SYSCLK. Every wait is BOUNDED: a rail that never readies
 * HANGS (board_clock_fault) rather than continue on a degraded clock. */
void board_clock_init(void) {
	uint32_t t;

	/* 1. Core supply = on-board LDO. The H723 is a value-line part with NO SMPS — its
	 *    PWR_CR3 has only LDOEN/BYPASS (no SMPS* bits exist to clear). Set LDOEN, clear
	 *    BYPASS. A supply write that mismatches the board browns out VCORE and locks the
	 *    debugger — recover with st-flash --connect-under-reset. */
	PWR->CR3 = (PWR->CR3 & ~PWR_CR3_BYPASS) | PWR_CR3_LDOEN;
	for (t = 0; (PWR->CSR1 & PWR_CSR1_ACTVOSRDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault(); /* supply not ready -> hang (hard fault) */
	}

	/* 2. HSE (8 MHz bypass from the ST-LINK MCO): PLL source + FDCAN kernel clock. */
	RCC->CR |= RCC_CR_HSEBYP | RCC_CR_HSEON;
	for (t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault();
	}

	/* 3. VOS1 (400 MHz-capable VCORE). On the H72x/73x `D3CR |= VOS` (both bits) is the
	 *    top level; we drive PLL to 400 to stay at the proven -Q point. */
	PWR->D3CR |= PWR_D3CR_VOS;
	for (t = 0; (PWR->D3CR & PWR_D3CR_VOSRDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault();
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
		if (t >= 4000000u) board_clock_fault(); /* PLL didn't lock -> hang (hard fault) */
	}

	/* 7. Switch SYSCLK to PLL1 (400 MHz). */
	RCC->CFGR = (RCC->CFGR & ~RCC_CFGR_SW) | RCC_CFGR_SW_PLL1;
	for (t = 0; (RCC->CFGR & RCC_CFGR_SWS) != RCC_CFGR_SWS_PLL1; t++) {
		if (t >= 4000000u) board_clock_fault();
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
	/* BOUNDED, like board_clock_init's HSE wait. In practice unreachable — board_clock_init
	 * already brought HSE up (or hung), so HSE is ready here — but a never-ready HSE hangs
	 * (board_clock_fault) for the same reason: FDCAN off its 8 MHz kernel clock is unusable. */
	for (uint32_t t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault();
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
	if (port == 7 && (pin == 0 || pin == 1)) return 1;   /* PH0/PH1: 8 MHz HSE pair — PLL1 AND the FDCAN kernel clock (re-muxing it kills both) */
	if (port == 0 && (pin == 13 || pin == 14)) return 1; /* PA13/PA14: SWD */
	if (port == 1 && pin == 3) return 1;                 /* PB3: SWO */
	/* RMII Ethernet (boards/h723/eth.c, all AF11): an [io] point re-muxing any of these
	 * pads after eth_pins_init would silently kill part of the MAC (codex, #247). */
	if (port == 0 && (pin == 1 || pin == 2 || pin == 7)) return 1; /* PA1 REF_CLK / PA2 MDIO / PA7 CRS_DV */
	if (port == 1 && pin == 13) return 1;                          /* PB13 TXD1 */
	if (port == 2 && (pin == 1 || pin == 4 || pin == 5)) return 1; /* PC1 MDC / PC4 RXD0 / PC5 RXD1 */
	if (port == 6 && (pin == 11 || pin == 13)) return 1;           /* PG11 TX_EN / PG13 TXD0 */
	return 0;
}

/* Bonded pads on the NUCLEO-H723ZG's LQFP144 (same package as the -Q): ports A..G are fully
 * bonded, PH0/PH1 are the HSE pair, nothing beyond exists. Without this override an [io] point
 * on an unbonded pad (e.g. PI0) would pass the driver's legacy weak default (accepts any PA..PK)
 * and a handler would drive a nonexistent pin instead of reporting the startup fault. */
int board_io_pin_exists(int port, int pin) {
	if (port >= 0 && port <= 6) return pin <= 15;    /* PA..PG complete */
	if (port == 7) return pin <= 1;                  /* PH0/PH1 (osc pair) */
	return 0;                                        /* PI/PJ/PK: not bonded */
}

/* Weak default for the shared ETH interrupt vector (boards/common/vectors.S IRQ61):
 * this node has no ETH driver, so absorb the vector's .word so the common table links. */
__attribute__((weak)) void ETH_IRQHandler(void) {
}

/* board_io_pwm_map: pin -> (timer base, channel, AF number, timer kernel clock), same
 * contract as boards/h755zi (REQ-IO-022: a pad without a mapping fails cfg loudly). Timer
 * kernel clock on this tree: HPRE = /2 and both D2PPREx = /2, so every APB timer's kernel
 * clock is 2x APB = HCLK = SYSCLK/2. Only the LD3 pad is mapped so far — extend as points
 * need pads. LD3 bench-verified (system_full: 1 kHz carrier, duty follows the routed signal). */
int board_io_pwm_map(int port, int pin, void **tim_base, int *chan, int *af, unsigned int *clk_hz) {
	if (g_cpu_mhz <= 64u) return -1; /* HSI fallback: reject rather than emit a wrong carrier */
	unsigned int tclk = g_cpu_mhz * 500000u; /* MHz/2 -> Hz */
	if (port == 1 && pin == 14) { *tim_base = TIM12; *chan = 1; *af = 2; *clk_hz = tclk; return 0; } /* PB14 TIM12_CH1 (red LD3) */
	return -1; /* pad not in the PWM map */
}
