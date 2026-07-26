/* STM32H735G-DK board bring-up for the h735_app showcase — register-level, no HAL.
 *
 * Same FDCAN1 bring-up as h735_canecho, plus a bare-metal timebase: the Loom and the
 * telemetry loop need a monotonic microsecond clock (host/sim gets it from POSIX
 * clock_gettime; on target there is none), so we run the Cortex-M7 DWT cycle counter
 * and divide by the achieved CPU MHz.
 *
 * FDCAN1: PH13 = FDCAN1_TX, PH14 = FDCAN1_RX (AF9) — the onboard CAN-FD transceiver.
 * FDCAN2: PB6 = FDCAN2_TX, PB5 = FDCAN2_RX (AF9), muxed for the system_full gateway's second
 * (edge) bus; PB5/6 are clear of the RMII Ethernet pins. This pin pair drives raw CANH/CANL
 * only through a transceiver — the FDCAN2 edge bus was bench-verified via the H735-DK, but
 * confirm your wiring provides a transceiver on PB5/PB6 (onboard or external) for that bus.
 * HSE is X1, a 25 MHz *oscillator* (NZ2520SH), so it runs in BYPASS.
 */
#include <stm32h735xx.h>

/* Achieved CPU frequency in MHz, i.e. DWT cycles per microsecond. Starts at the HSI
 * reset value; board_clock_init() bumps it to 550 once SYSCLK is confirmed on PLL1 (and
 * hangs otherwise), so board_now_us() only ever runs at the rated clock. */
static volatile uint32_t g_cpu_mhz = 64;

/* board_clock_fault — a clock we can't bring up is a HARD FAULT, not a limp (an ECU on the
 * wrong clock violates its real-time timing). Hang deterministically; SWD reads the PC + the
 * RCC/PWR registers to see which rail failed. Unreachable on healthy silicon. Same policy as
 * boards/h755zi and boards/h723. */
static void __attribute__((noreturn)) board_clock_fault(void) {
	for (;;) {
	}
}

/* board_clock_init: bring the Cortex-M7 to its full 550 MHz. Chain: Direct-SMPS
 * supply -> VOS0 -> flash wait-states -> PLL1 (25/5*220/2 = 550 MHz) -> switch
 * SYSCLK. Every wait is BOUNDED: a rail that never readies HANGS (board_clock_fault)
 * rather than continue on a degraded clock. FDCAN kernel clock stays HSE 25 MHz.
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
		if (t >= 4000000u) board_clock_fault(); /* supply not ready -> hang (hard fault) */
	}

	/* 2. HSE (25 MHz bypass): PLL source (also the FDCAN kernel clock). */
	RCC->CR |= RCC_CR_HSEBYP | RCC_CR_HSEON;
	for (t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault();
	}

	/* 3. VOS0 (highest VCORE) — required for 550 MHz. */
	PWR->D3CR |= PWR_D3CR_VOS;
	for (t = 0; (PWR->D3CR & PWR_D3CR_VOSRDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault(); /* VOS0 not reached -> hang (hard fault) */
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
		if (t >= 4000000u) board_clock_fault(); /* PLL didn't lock -> hang (hard fault) */
	}

	/* 7. Switch SYSCLK to PLL1 (550 MHz). */
	RCC->CFGR = (RCC->CFGR & ~RCC_CFGR_SW) | RCC_CFGR_SW_PLL1;
	for (t = 0; (RCC->CFGR & RCC_CFGR_SWS) != RCC_CFGR_SWS_PLL1; t++) {
		if (t >= 4000000u) board_clock_fault();
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
 * The last/acc_cycles statics are shared: on a ThreadX build BOTH the FB thread and the
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
	/* BOUNDED, like board_clock_init's HSE wait. Unreachable in practice — board_clock_init
	 * already brought HSE up (or hung) — but a never-ready HSE hangs (board_clock_fault): FDCAN
	 * off its 25 MHz kernel clock is unusable. */
	for (uint32_t t = 0; (RCC->CR & RCC_CR_HSERDY) == 0u; t++) {
		if (t >= 4000000u) board_clock_fault();
	}
	RCC->D2CCIP1R &= ~RCC_D2CCIP1R_FDCANSEL; /* 00 -> HSE (25 MHz) */

	/* 2. FDCAN peripheral (APB1H) clock, for register access. */
	RCC->APB1HENR |= RCC_APB1HENR_FDCANEN;

	/* One FDCANEN bit clocks all instances; each just needs its GPIO AF muxed. */

	/* 3. FDCAN1 on GPIOH: PH13 = TX, PH14 = RX, AF9. */
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

	/* 4. FDCAN2 on GPIOB: PB6 = TX, PB5 = RX, AF9 (the DK's second CAN-FD transceiver;
	 *    PB5/PB6 are clear of the RMII Ethernet pins, unlike the PB12 map other boards use).
	 *    system_full's gateway routes the `edge` bus here. */
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOBEN;
	(void)RCC->AHB4ENR;

	/* MODER: PB5, PB6 -> alternate function (0b10). */
	GPIOB->MODER &= ~((3u << (5u * 2u)) | (3u << (6u * 2u)));
	GPIOB->MODER |= ((2u << (5u * 2u)) | (2u << (6u * 2u)));

	/* OSPEEDR: very high speed. */
	GPIOB->OSPEEDR |= (3u << (5u * 2u)) | (3u << (6u * 2u));

	/* AFR[0] holds the AF nibble for pins 0..7. AF9 = FDCAN2. */
	GPIOB->AFR[0] &= ~((0xFu << (5u * 4u)) | (0xFu << (6u * 4u)));
	GPIOB->AFR[0] |= ((9u << (5u * 4u)) | (9u << (6u * 4u)));
}

/* Platform pin-ownership table (board.h, docs/io.md "pins are exclusive"): pads this
 * board already assigned — an io point re-muxing one would silently kill CAN, the
 * debugger, or the PHY. Port index 0=A..10=K (the io_stm32.c parse). */
int board_io_pin_reserved(int port, int pin) {
	if (port == 7 && (pin == 0 || pin == 1)) return 1;   /* PH0/PH1: HSE pair — the PLL AND FDCAN clock source */
	if (port == 1 && pin == 3) return 1;                 /* PB3: SWO */
	if (port == 0 && (pin == 13 || pin == 14)) return 1;            /* PA13/PA14: SWD */
	if (port == 7 && (pin == 13 || pin == 14)) return 1;            /* PH13/PH14: FDCAN1 TX/RX */
	if (port == 1 && (pin == 5 || pin == 6)) return 1;             /* PB5/PB6: FDCAN2 RX/TX */
	if (port == 0 && (pin == 1 || pin == 2 || pin == 7)) return 1;  /* PA1/2/7: RMII REF_CLK/MDIO/CRS_DV (eth.c) */
	if (port == 1 && (pin == 11 || pin == 12 || pin == 13)) return 1; /* PB11/12/13: RMII TX_EN/TXD0/TXD1 */
	if (port == 2 && (pin == 1 || pin == 4 || pin == 5)) return 1;  /* PC1/4/5: RMII MDC/RXD0/RXD1 */
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
	return -1; /* pad not in the PWM map */
}

/* Bonded pads on the H735G-DK's STM32H735IGK6 (UFBGA176): ports A..I carry
 * application-reachable pads; PJ/PK on this package serve the DK's LCD/octo-SPI
 * fabric and are not offered as io points. BOARD-DECLARED map (not a datasheet
 * import): a point on a pad the schematic routes elsewhere still fails honestly
 * at the electrical level, and the reserved() table above holds the pads the
 * platform actively owns — extend BOTH from the schematic when a config first
 * needs a contested pad. */
int board_io_pin_exists(int port, int pin) {
	if (port >= 0 && port <= 7) return pin <= 15;    /* PA..PH: fully bonded */
	if (port == 8) return pin <= 11;                 /* PI: bonded only through PI11 (UFBGA176) */
	return 0;                                        /* PJ/PK: LCD/OSPI fabric */
}

/* Weak default for the ETH interrupt (vectors.S IRQ61). Images that link the ETH
 * driver (boards/h735dk/eth.c) override this with the strong ETH_IRQHandler; every
 * other image resolves the vector's .word here so the shared table still links.
 * Separate object from vectors.S — no --gc-sections relocation-capture. */
__attribute__((weak)) void ETH_IRQHandler(void) {
}
