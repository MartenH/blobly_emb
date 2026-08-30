/* NUCLEO-H755ZI-Q board bring-up (Cortex-M7 side) — register-level, no HAL.
 *
 * Adapted from boards/h735dk with the -Q Nucleo's realities:
 *  - Direct SMPS supply (same as the DK), but on the H745/55 family that RULES OUT the
 *    VOS0 boost point — the ceiling is VOS1 = 400 MHz. Conveniently `PWR->D3CR |= VOS`
 *    (both bits) means "VOS0" on the H72x/73x and "VOS1" on the H74x/75x: the same write
 *    yields each family's highest SMPS-legal level.
 *  - HSE is 8 MHz from the ST-LINK MCO (bypass), not the DK's 25 MHz oscillator. The
 *    PLL constants and the FDCAN bit timing (see board.mk) differ accordingly.
 *  - FDCAN1 on PD0 = RX, PD1 = TX (AF9) — the Zio CN9 header, wired to an external
 *    TLE9251V transceiver (the Nucleo has no CAN transceiver populated).
 *
 * Dual-core note: this file is CM7-only bring-up (one core owns RCC/PWR). The CM4 is
 * not started by us; with an erased bank 2 it locks up harmlessly at boot.
 */
#include <stm32h755xx.h>

/* Achieved CPU frequency in MHz, i.e. DWT cycles per microsecond. Starts at the HSI
 * reset value; board_clock_init() bumps it to 400 once SYSCLK is confirmed on PLL1 (and
 * hangs otherwise), so board_now_us() only ever runs at the rated clock. */
static volatile uint32_t g_cpu_mhz = 64;

/* board_clock_fault — a clock we can't bring up is a HARD FAULT, not a limp: an ECU on the
 * wrong clock violates its real-time timing (ThreadX's SysTick assumes SYSTEM_CLOCK, so a
 * downgraded core runs several times slow) and the FDCAN kernel clock rides the same HSE, so
 * "stay alive to diagnose over CAN" doesn't even hold. Hang deterministically — SWD reads the
 * PC (stuck here) and the RCC/PWR registers to see which rail failed. Unreachable on healthy
 * silicon (a good board always locks PLL1). */
static void __attribute__((noreturn)) board_clock_fault(void) {
	for (;;) {
	}
}

/* board_clock_init: bring the Cortex-M7 to 400 MHz (VOS1 ceiling on the SMPS-supplied
 * -Q board). Chain: Direct-SMPS supply -> VOS1 -> flash wait-states -> PLL1
 * (8/2*200/2 = 400 MHz) -> switch SYSCLK. Every wait is BOUNDED: if a rail never
 * readies we HANG (board_clock_fault) rather than continue on a degraded clock.
 *
 * The supply write MUST match the board wiring (Direct SMPS on the -Q Nucleo); a
 * mismatch browns out VCORE and locks the debugger — recover with
 * st-flash --connect-under-reset. */
void board_clock_init(void) {
	uint32_t t;

	/* 1. Core supply = Direct SMPS (SMPSEN on, LDO/bypass off) — matches the -Q board. */
	PWR->CR3 = (PWR->CR3 & ~(PWR_CR3_SMPSLEVEL | PWR_CR3_SMPSEXTHP | PWR_CR3_LDOEN | PWR_CR3_BYPASS))
	         | PWR_CR3_SMPSEN;
	for (t = 0; (PWR->CSR1 & PWR_CSR1_ACTVOSRDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault(); /* supply not ready -> hang (hard fault) */
	}

	/* 2. HSE (8 MHz bypass from the ST-LINK MCO): PLL source + FDCAN kernel clock. */
	RCC->CR |= RCC_CR_HSEBYP | RCC_CR_HSEON;
	for (t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault();
	}

	/* 3. VOS1 (the highest SMPS-legal VCORE on this family) — required for 400 MHz. */
	PWR->D3CR |= PWR_D3CR_VOS;
	for (t = 0; (PWR->D3CR & PWR_D3CR_VOSRDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault(); /* VOS1 not reached -> hang (hard fault) */
	}

	/* 4. Flash wait-states for 200 MHz AXI @ VOS1: 2 WS, WRHIGHFREQ = 0b10. */
	FLASH->ACR = FLASH_ACR_LATENCY_2WS | (0x2UL << FLASH_ACR_WRHIGHFREQ_Pos);

	/* 5. Bus prescalers: CPU /1 (400), AHB /2 (200), APB1/2/3/4 /2 (100 MHz). */
	RCC->D1CFGR = RCC_D1CFGR_D1CPRE_DIV1 | RCC_D1CFGR_HPRE_DIV2 | RCC_D1CFGR_D1PPRE_DIV2;
	RCC->D2CFGR = RCC_D2CFGR_D2PPRE1_DIV2 | RCC_D2CFGR_D2PPRE2_DIV2;
	RCC->D3CFGR = RCC_D3CFGR_D3PPRE_DIV2;

	/* 6. PLL1 from HSE: /2 = 4 MHz ref (RGE 4-8), x200 = 800 MHz VCO (wide), /2 = 400 MHz.
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

	/* 8. Instruction cache — non-negotiable (see boards/h735dk/board.c: without it a
	 * tight loop's throughput is a flash-fetch alignment lottery). D-cache stays off
	 * on purpose: nothing DMAs, and cross-core shared-SRAM IOC stays coherency-free. */
	SCB_EnableICache();
}

/* board_timebase_init: start the DWT cycle counter (free-running, 32-bit). */
void board_timebase_init(void) {
	CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk; /* enable the trace/debug block */
	DWT->CYCCNT = 0u;
	DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

/* board_now_us: monotonic microseconds since board_timebase_init(). 32-bit CYCCNT
 * wraps every ~10.7 s at 400 MHz; deltas accumulate into a 64-bit counter. PRIMASK
 * guard: on a ThreadX build multiple threads + ISRs call this (see boards/h735dk). */
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
	/* 1. HSE in bypass (ST-LINK MCO), on, then select it as the FDCAN kernel clock
	 *    (FDCANSEL = 00 = HSE, 8 MHz — the bit timing in board.mk assumes this). */
	RCC->CR |= RCC_CR_HSEBYP;
	RCC->CR |= RCC_CR_HSEON;
	while ((RCC->CR & RCC_CR_HSERDY) == 0u) {
	}
	RCC->D2CCIP1R &= ~RCC_D2CCIP1R_FDCANSEL; /* 00 -> HSE (8 MHz) */

	/* 2. FDCAN peripheral (APB1H) clock, for register access. */
	RCC->APB1HENR |= RCC_APB1HENR_FDCANEN;

	/* 3. GPIOD clock, then mux PD0 (FDCAN1_RX) / PD1 (FDCAN1_TX) to AF9. These are on
	 *    the Zio CN9 header — no solder, jumper wires to the TLE9251V. */
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIODEN;
	(void)RCC->AHB4ENR; /* read-back: let the clock settle before touching GPIOD */

	/* MODER: PD0, PD1 -> alternate function (0b10). */
	GPIOD->MODER &= ~((3u << (0u * 2u)) | (3u << (1u * 2u)));
	GPIOD->MODER |= ((2u << (0u * 2u)) | (2u << (1u * 2u)));

	/* OSPEEDR: very high speed (clean CAN edges). */
	GPIOD->OSPEEDR |= (3u << (0u * 2u)) | (3u << (1u * 2u));

	/* AFR[0] holds the AF nibble for pins 0..7. AF9 = FDCAN1. */
	GPIOD->AFR[0] &= ~((0xFu << (0u * 4u)) | (0xFu << (1u * 4u)));
	GPIOD->AFR[0] |= ((9u << (0u * 4u)) | (9u << (1u * 4u)));
}

/* Platform pin-ownership table (board.h, docs/io.md "pins are exclusive"): pads this
 * board already assigned — an io point re-muxing one would silently kill CAN or the
 * debugger. Port index 0=A..10=K (the io_stm32.c parse). */
int board_io_pin_reserved(int port, int pin) {
	if (port == 3 && (pin == 0 || pin == 1)) return 1;   /* PD0/PD1: FDCAN1 RX/TX */
	if (port == 7 && (pin == 0 || pin == 1)) return 1;   /* PH0/PH1: HSE pair — the PLL AND FDCAN clock source */
	if (port == 0 && (pin == 13 || pin == 14)) return 1; /* PA13/PA14: SWD */
	if (port == 1 && pin == 3) return 1;                 /* PB3: SWO */
	return 0;
}

/* board_io_pwm_map: pin -> (timer base, channel, AF number, timer kernel clock).
 * The driver (driver/io/io_stm32.c) programs the timer from this; a pad without a
 * mapping fails cfg (REQ-IO-022). DRY-CODED from the datasheet AF table, bench-
 * pending. Timer kernel clock: the APB timers run at 2x their APBx clock when the
 * APB prescaler is > 1 (this board's clock tree) — confirm the exact value on the
 * bench for a precise carrier. Extend the table as points need pads. */
int board_io_pwm_map(int port, int pin, void **tim_base, int *chan, int *af, unsigned int *clk_hz) {
	/* timer kernel clock = HCLK = SYSCLK/2 on this board's tree, tracked via the
	 * achieved g_cpu_mhz (set only on PLL success). If bring-up degraded to HSI
	 * (g_cpu_mhz still 64), reject PWM rather than emit a several-times-wrong
	 * carrier (codex emb#152). */
	if (g_cpu_mhz <= 64u) return -1;
	unsigned int tclk = g_cpu_mhz * 500000u; /* MHz/2 -> Hz */
	/* port: 0=A..10=K. TIM1 (AF1) channels on the common H7 pads. */
	if (port == 4 && pin == 9)  { *tim_base = TIM1; *chan = 1; *af = 1; *clk_hz = tclk; return 0; } /* PE9  TIM1_CH1 */
	if (port == 4 && pin == 11) { *tim_base = TIM1; *chan = 2; *af = 1; *clk_hz = tclk; return 0; } /* PE11 TIM1_CH2 */
	if (port == 0 && pin == 8)  { *tim_base = TIM1; *chan = 1; *af = 1; *clk_hz = tclk; return 0; } /* PA8  TIM1_CH1 */
	if (port == 0 && pin == 0)  { *tim_base = TIM2; *chan = 1; *af = 1; *clk_hz = tclk; return 0; } /* PA0  TIM2_CH1 */
	/* the Nucleo's red LD3. TIM12 is on APB1 (D2PPRE1 = /2 -> timer kernel = 2x APB1 = HCLK),
	 * the same tclk as the APB2 timers above on this tree. */
	if (port == 1 && pin == 14) { *tim_base = TIM12; *chan = 1; *af = 2; *clk_hz = tclk; return 0; } /* PB14 TIM12_CH1 */
	return -1; /* pad not in the PWM map */
}

/* Bonded pads on the NUCLEO-H755ZI-Q's LQFP144: ports A..G are fully bonded,
 * PH0/PH1 are the HSE pair, nothing beyond exists on this package. */
int board_io_pin_exists(int port, int pin) {
	if (port >= 0 && port <= 6) return pin <= 15;    /* PA..PG complete */
	if (port == 7) return pin <= 1;                  /* PH0/PH1 (osc pair) */
	return 0;                                        /* PI/PJ/PK: not bonded */
}

/* Weak default for the ETH interrupt (boards/common/vectors.S IRQ61), shared with
 * the H735. The H755 has no ETH driver yet, so this absorbs the vector's .word so
 * the common table links; a future net driver overrides it with a strong handler. */
__attribute__((weak)) void ETH_IRQHandler(void) {
}
