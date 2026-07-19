/* STM32 H7 target backend: register-level GPIO, no HAL (the can_fdcan.c style).
 *
 * The pin string ("PB0", "PC13") is parsed at cfg time into port/pin indexes;
 * blob_io_init() then brings each configured point up in the docs/io.md order —
 * for an OUTPUT the init level is written to BSRR BEFORE the pin is muxed from
 * its reset state (analog) to output mode, so there is no glitch window through
 * a floating pin into an active-high actuator (REQ-IO-009/013). Inputs are
 * plain MODER=input, no pull (the Nucleo button has its own RC network).
 *
 * Reads are one IDR load (REQ-IO-008, trivially wait-free) and cannot fail on
 * target — read_checked always has a real sample, and last-good bookkeeping
 * (the host mirror's torn-file rule, REQ-IO-003) has nothing to serve. Writes
 * are one BSRR store: atomic set/reset, no read-modify-write, so no faults to
 * count either. Same static 32-entry table shape as io_file.c; no heap. */
#include "io_port.h"
#include "board.h"    /* board_io_pin_reserved: the boards-layer pin-ownership table */
#include <stm32h7xx.h>

/* The ADC pre-channel-select register is at offset 0x1C on all H7, but CMSIS
 * names it PCSEL on H74x/H75x and PCSEL_RES0 on the H72x/H73x device headers.
 * Same register — select the member by the build's part define. */
#if defined(STM32H723xx) || defined(STM32H725xx) || defined(STM32H730xx) || \
    defined(STM32H733xx) || defined(STM32H735xx) || defined(STM32H73xx)
#define ADC_PCSEL PCSEL_RES0
#else
#define ADC_PCSEL PCSEL
#endif /* CMSIS family dispatcher (build sets -DSTM32H735xx / -DSTM32H755xx); no HAL */

#define BLOB_IO_MAX 32

/* *** ADC + PWM paths are DRY-CODED (bench-unverified) — written from RM0399,
 * no silicon run yet. The ADC1 continuous-scan/circular-DMA setup, the pin->
 * channel map, and the timer-PWM register sequence are all on the P2/P3 bench
 * checklist. GPIO is silicon-verified (emb#150). *** */
#define IO_GPIO 0
#define IO_ADC 1
#define IO_PWM 2

static struct {
	unsigned int port; /* 0..10 = GPIOA..GPIOK, parsed from the pin string at cfg */
	unsigned int pin;  /* 0..15 */
	int dir;           /* 0=in 1=out */
	int kind;          /* IO_GPIO / IO_ADC / IO_PWM */
	unsigned int init; /* gpio: PAD level (logical init ^ al); pwm: init permille */
	unsigned int al;   /* active_low: invert logical<->pad (gpio) */
	int adc_slot;      /* adc: index into g_adc_dma[]; -1 otherwise */
	unsigned int adc_ch; /* adc: ADC1 channel number */
	unsigned int freq_hz; /* pwm: carrier */
	int configured;
} g_pt[BLOB_IO_MAX];

/* circular-DMA latest-value array: one u16 per ADC point, in cfg order. The DMA
 * writes it continuously; the io thread does a single aligned 16-bit load
 * (atomic on M7) — wait-free (REQ-IO-018). */
/* g_adc_dma MUST live in DMA-reachable SRAM: ordinary .bss is DTCM on these
 * boards (threadx.ld RAM @ 0x20000000), which DMA1 cannot access — the samples
 * would stay zero or raise a transfer error. .dma_buf is placed in D2 AHB SRAM
 * (0x30000000) by the linker, the same region the ETH descriptors use (codex
 * emb#152). */
__attribute__((section(".dma_buf"))) static volatile unsigned short g_adc_dma[BLOB_IO_MAX];
static int g_adc_n;            /* number of ADC points (== ranked length of the scan) */
static int g_adc_first_ready;  /* set once DMA has delivered the first full scan */

/* pin -> ADC1 channel (STM32H7 ADC1, RM0399 tbl). Small map: bench-extend as
 * points need pads. -1 = not an ADC1-capable pad on this map. */
static int adc_dma_start(void);
static int pwm_setup(int ch);
static int adc_channel_of(unsigned int port, unsigned int pin) {
	if (port == 0) { /* GPIOA */
		switch (pin) {
		case 0: return 16; case 1: return 17; case 2: return 14; case 3: return 15;
		case 4: return 18; case 5: return 19; case 6: return 3;  case 7: return 7;
		}
	} else if (port == 1) { /* GPIOB */
		if (pin == 0) return 9;
		if (pin == 1) return 5;
	} else if (port == 2) { /* GPIOC */
		switch (pin) {
		case 0: return 10; case 1: return 11; case 2: return 12; case 3: return 13;
		case 4: return 4;  case 5: return 8; /* PC4/PC5 are INP4/INP8, NOT 14/15 */
		}
	}
	return -1;
}

/* H7 GPIO blocks sit at a fixed 0x400 stride from GPIOA on AHB4; parts without
 * GPIOI (H72x/H73x) simply reserve that slot, so the arithmetic holds on both
 * benches. Same story for the AHB4ENR enable bits: GPIOAEN..GPIOKEN are bits
 * 0..10 in port-letter order. */
static GPIO_TypeDef *gpio(unsigned int port) {
	return (GPIO_TypeDef *)(GPIOA_BASE + (uint32_t)port * 0x0400UL);
}

/* "PA0".."PK15" -> port/pin indexes; anything else (no P, bad letter, no
 * digits, >15, trailing junk) is malformed and rejected at cfg. */
static int pin_parse(const char *s, unsigned int *port, unsigned int *pin) {
	if (!s || s[0] != 'P') return -1;
	if (s[1] < 'A' || s[1] > 'K') return -1;
	if (s[2] < '0' || s[2] > '9') return -1;
	unsigned int n = (unsigned int)(s[2] - '0');
	unsigned int i = 3;
	if (s[3] >= '0' && s[3] <= '9') {
		if (n == 0u) return -1; /* leading zero: "PB00" would alias PB0 — one
		                         * spelling per pad, so string-level exclusivity
		                         * above the driver stays sound (REQ-IO-006) */
		n = n * 10u + (unsigned int)(s[3] - '0');
		i = 4;
	}
	if (s[i] != '\0' || n > 15u) return -1;
	*port = (unsigned int)(s[1] - 'A');
	*pin = n;
	return 0;
}

/* Weak default: no platform-owned pads. Lives here (the only caller) so the
 * symbol always links; a board.c's strong table overrides it (board.h). */
__attribute__((weak)) int board_io_pin_reserved(int port, int pin) {
	(void)port;
	(void)pin;
	return 0;
}

/* board_io_pin_exists: the board's bonded-pad table (port 0=A..10=K). A pad can
 * be syntactically valid yet absent from this MCU/package — configuring it
 * "succeeds" into a floating nothing, so cfg rejects it up front (codex on
 * emb#150). Weak default says everything exists (legacy boards keep working);
 * each bench board declares its real map in board.c. */
__attribute__((weak)) int board_io_pin_exists(int port, int pin) {
	(void)port;
	(void)pin;
	return 1;
}

int blob_io_cfg(int ch, const char *name, const char *pin, int dir, unsigned int init_val, int active_low, int kind, unsigned int param) {
	(void)name; /* informational on target: the parsed pin IS the table key */
	if (ch < 0 || ch >= BLOB_IO_MAX || !name || !pin) return -1;
	if (pin_parse(pin, &g_pt[ch].port, &g_pt[ch].pin) < 0) return -1;
	/* the pad must be bonded on THIS package — an absent pad configures into a
	 * floating nothing and the init level never exists physically */
	if (!board_io_pin_exists((int)g_pt[ch].port, (int)g_pt[ch].pin)) return -1;
	/* docs/io.md "pins are exclusive" + REQ-IO-006: a pad the board assigned to
	 * CAN/SWD/ETH must never be re-muxed by an io point — reject before recording. */
	if (board_io_pin_reserved((int)g_pt[ch].port, (int)g_pt[ch].pin)) return -1;
	g_pt[ch].dir = dir ? 1 : 0;
	g_pt[ch].kind = kind;
	g_pt[ch].al = active_low ? 1u : 0u;
	g_pt[ch].adc_slot = -1;
	g_pt[ch].freq_hz = param;
	if (kind == IO_ADC) {
		int c = adc_channel_of(g_pt[ch].port, g_pt[ch].pin);
		if (c < 0) return -1; /* pad has no ADC1 channel on this map */
		g_pt[ch].adc_ch = (unsigned int)c;
		g_pt[ch].adc_slot = g_adc_n++;
		g_pt[ch].init = 0;
	} else if (kind == IO_PWM) {
		if (param == 0u) return -1; /* zero carrier */
		g_pt[ch].init = (init_val > 1000u) ? 1000u : init_val; /* permille */
	} else {
		/* gpio init is LOGICAL (REQ-IO-017): store the PAD level so blob_io_init's
		 * BSRR write needs no polarity knowledge */
		g_pt[ch].init = (init_val ? 1u : 0u) ^ g_pt[ch].al;
	}
	g_pt[ch].configured = 1;
	return 0;
}

int blob_io_init(void) {
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (!g_pt[i].configured) continue;
		GPIO_TypeDef *g = gpio(g_pt[i].port);
		unsigned int p = g_pt[i].pin;

		RCC->AHB4ENR |= (1u << g_pt[i].port); /* GPIOxEN, bits in port order */
		(void)RCC->AHB4ENR; /* read-back: let the clock settle before touching the port */

		if (g_pt[i].kind == IO_ADC) {
			g->MODER |= (3u << (p * 2u));  /* 11 = analog */
			g->PUPDR &= ~(3u << (p * 2u)); /* no pull on an analog pad */
		} else if (g_pt[i].kind == IO_PWM) {
			/* pin stays a plain INPUT here — pwm_setup() muxes it to AF only AFTER
			 * the timer is configured and the init duty loaded, so the pad never
			 * floats in AF driven by an unconfigured timer (codex emb#152). */
			g->OSPEEDR |= (2u << (p * 2u)); /* medium: a 20 kHz carrier has real edges */
			g->PUPDR &= ~(3u << (p * 2u));
		} else if (g_pt[i].dir) {
			/* output: establish the init level in ODR via BSRR FIRST, while the
			 * pin still sits in its reset state — then mux to output, so the pad
			 * goes straight to the configured level (REQ-IO-009, docs/io.md). */
			g->BSRR = g_pt[i].init ? (1u << p) : (1u << (p + 16u));
			g->MODER = (g->MODER & ~(3u << (p * 2u))) | (1u << (p * 2u)); /* 01 = output */
			g->OSPEEDR &= ~(3u << (p * 2u)); /* 00 = low speed: LED/logic cadence, no fast edges */
			g->PUPDR &= ~(3u << (p * 2u));   /* no pull on a driven pad */
		} else {
			g->MODER &= ~(3u << (p * 2u)); /* 00 = input */
			g->PUPDR &= ~(3u << (p * 2u)); /* no pull: the board's button has external RC */
		}
	}
	int pwm_fault = 0;
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (g_pt[i].configured && g_pt[i].kind == IO_PWM) {
			if (pwm_setup(i) != 0)
				pwm_fault = 1; /* configure EVERY valid pwm before failing (codex emb#152) */
		}
	}
	if (pwm_fault)
		return -1; /* some pwm point had no/invalid map — fail after the valid ones ran */
	if (g_adc_n > 0) {
		if (adc_dma_start() != 0)
			return -1; /* silent/absent converter: bounded-wait timed out -> startup fault */
	}
	return 0;
}

int blob_io_gpio_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return 0;
	/* pad -> LOGICAL (REQ-IO-017): an active-low input asserts on a low pad */
	return (((gpio(g_pt[ch].port)->IDR >> g_pt[ch].pin) & 1u) ^ g_pt[ch].al) ? 1 : 0;
}

int blob_io_gpio_read_checked(int ch, int *val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || !val) return -1;
	/* a real pad always samples: same IDR load, never a fabricated value */
	*val = blob_io_gpio_read(ch);
	return 0;
}

void blob_io_gpio_write(int ch, int level) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return;
	unsigned int p = g_pt[ch].pin;
	unsigned int lv = (level ? 1u : 0u) ^ g_pt[ch].al; /* LOGICAL -> pad (REQ-IO-017) */
	gpio(g_pt[ch].port)->BSRR = lv ? (1u << p) : (1u << (p + 16u)); /* atomic, no RMW */
}

unsigned int blob_io_write_faults(void) {
	return 0; /* a BSRR store cannot fail; only the host mirror has write faults */
}


/* A bounded spin: ~N loop iterations. Returns 1 if `cond` became true, 0 on
 * timeout — no hardware wait may hang blob_io_init (the silent-converter path
 * must reach the startup-fault leg, codex emb#152). */
#define IO_WAIT(cond, iters) ({ int _ok = 0; for (volatile unsigned _w = 0; _w < (iters); _w++) { if (cond) { _ok = 1; break; } } _ok; })

/* adc_dma_start: ADC1 in continuous scan over the configured channels, results
 * DMA'd circularly into g_adc_dma — free-running, no interrupts (REQ-IO-018).
 * DRY-CODED from RM0399, bench-pending. Returns 0 on success, -1 if a bounded
 * hardware wait times out. */
static int adc_dma_start(void) {
	DMA1->LIFCR = DMA_LIFCR_CTCIF0; /* drop a stale scan-complete flag up front so a
	                                 * degraded exit below can't leave first-ready fakeable */
	g_adc_first_ready = 0;
	/* ADC KERNEL clock: the reset mux is PLL2_P, which board_clock_init never
	 * enables (only PLL1) — select per_ck (ADCSEL=0b10 in D3CCIPR), sourced from
	 * the always-on HSI, so calibration has a clock without depending on a PLL2
	 * the board doesn't bring up (codex emb#152). */
	RCC->D3CCIPR = (RCC->D3CCIPR & ~RCC_D3CCIPR_ADCSEL) | (2u << RCC_D3CCIPR_ADCSEL_Pos);
	RCC->AHB1ENR |= RCC_AHB1ENR_ADC12EN | RCC_AHB1ENR_DMA1EN;
	/* clock the D2 AHB SRAM banks: the linker places .dma_buf in SRAM3 (H755, AMP-
	 * safe) or SRAM1 (H735, shared with ETH). Guarded — the H72x/H73x parts have
	 * fewer banks than H74x/H75x (codex emb#152). */
	RCC->AHB2ENR |= 0u
#ifdef RCC_AHB2ENR_SRAM1EN
	              | RCC_AHB2ENR_SRAM1EN
#endif
#ifdef RCC_AHB2ENR_SRAM2EN
	              | RCC_AHB2ENR_SRAM2EN
#endif
#ifdef RCC_AHB2ENR_SRAM3EN
	              | RCC_AHB2ENR_SRAM3EN
#endif
	              ;
	(void)RCC->AHB2ENR;

	/* ADC common prescaler: per_ck is the 64 MHz HSI; the H7 ADC fADC ceiling is
	 * ~50 MHz (boost banding). Divide by 2 -> 32 MHz, in range, and set BOOST for
	 * the 25..50 MHz band (codex emb#152). */
	ADC12_COMMON->CCR = (ADC12_COMMON->CCR & ~ADC_CCR_PRESC) | (2u << ADC_CCR_PRESC_Pos); /* /4 -> 16 MHz */
	ADC1->CR = (ADC1->CR & ~ADC_CR_BOOST) | ADC_CR_BOOST_1; /* BOOST=0b10: 12.5..25 MHz band */

	/* exit deep-power-down, enable the regulator, let the LDO settle */
	ADC1->CR &= ~ADC_CR_DEEPPWD;
	ADC1->CR |= ADC_CR_ADVREGEN;
	for (volatile int w = 0; w < 20000; w++) { } /* > 10 us LDO startup */

	/* calibrate (single-ended) — BOUNDED. Degraded, not fatal: a timeout leaves
	 * g_adc_first_ready 0 so the checked reads fault per-point, without failing
	 * blob_io_init and taking down valid OUTPUTS (codex emb#152). */
	ADC1->CR &= ~ADC_CR_ADCALDIF;
	ADC1->CR |= ADC_CR_ADCAL;
	if (!IO_WAIT(!(ADC1->CR & ADC_CR_ADCAL), 1000000u)) return 0;

	/* 12-bit (RES=0b010; RES=0 would be 16-bit — the examples scale by 4095),
	 * right-aligned; continuous + DMA circular (DMNGT=11) */
	ADC1->CFGR = ADC_CFGR_CONT | ADC_CFGR_DMNGT_0 | ADC_CFGR_DMNGT_1
	           | (2u << ADC_CFGR_RES_Pos);

	/* the regular sequence: g_adc_n ranks, in cfg/slot order. The H7 SQR layout
	 * is NOT uniform: SQR1 holds L + SQ1..SQ4 (bits 6,12,18,24); SQR2 SQ5..SQ9,
	 * SQR3 SQ10..SQ14, SQR4 SQ15..SQ16 — five/five/two, each at bits 0,6,12,...
	 * (codex emb#152: the flat 6-per-reg math truncated rank 10+). */
	unsigned int sqr[4] = { (unsigned int)(g_adc_n - 1), 0, 0, 0 };
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (!g_pt[i].configured || g_pt[i].kind != IO_ADC) continue;
		unsigned int r = (unsigned int)g_pt[i].adc_slot + 1u; /* rank 1..16 */
		unsigned int ch5 = g_pt[i].adc_ch & 0x1Fu;
		if (r <= 4u) {
			sqr[0] |= ch5 << (6u + (r - 1u) * 6u);       /* SQR1: SQ1..SQ4 at 6,12,18,24 */
		} else {
			unsigned int rr = r - 5u;                    /* 0-based across SQR2..SQR4 */
			unsigned int reg = 1u + rr / 5u;             /* five fields per SQR2/3/4 */
			unsigned int pos = (rr % 5u) * 6u;           /* bits 0,6,12,18,24 */
			if (reg <= 3u) sqr[reg] |= ch5 << pos;
		}
		if (g_pt[i].adc_ch < 10u) ADC1->SMPR1 |= (7u << (g_pt[i].adc_ch * 3u));
		else ADC1->SMPR2 |= (7u << ((g_pt[i].adc_ch - 10u) * 3u));
		ADC1->ADC_PCSEL |= (1u << g_pt[i].adc_ch); /* H7: a channel must be preselected to convert */
	}
	ADC1->SQR1 = sqr[0];
	ADC1->SQR2 = sqr[1];
	ADC1->SQR3 = sqr[2];
	ADC1->SQR4 = sqr[3];

	/* DMA1 Stream0: ADC1->DR -> g_adc_dma, 16-bit, circular, mem-increment */
	DMA1_Stream0->CR = 0;
	if (!IO_WAIT(!(DMA1_Stream0->CR & DMA_SxCR_EN), 100000u)) return 0; /* degraded, not fatal */
	DMA1_Stream0->PAR = (uint32_t)(&ADC1->DR);
	DMA1_Stream0->M0AR = (uint32_t)g_adc_dma;
	DMA1_Stream0->NDTR = (uint32_t)g_adc_n;
	DMAMUX1_Channel0->CCR = 9u; /* request 9 = adc1 (RM0399 DMAMUX table) */
	DMA1->LIFCR = DMA_LIFCR_CTCIF0 | DMA_LIFCR_CHTIF0 | DMA_LIFCR_CTEIF0
	            | DMA_LIFCR_CDMEIF0 | DMA_LIFCR_CFEIF0; /* clear stale flags (codex emb#152) */
	DMA1_Stream0->CR = DMA_SxCR_MINC | DMA_SxCR_CIRC |
	                   (1u << DMA_SxCR_MSIZE_Pos) | (1u << DMA_SxCR_PSIZE_Pos) |
	                   DMA_SxCR_EN;

	/* enable + start — BOUNDED ADRDY wait (degraded on timeout, not fatal) */
	ADC1->ISR = ADC_ISR_ADRDY;
	ADC1->CR |= ADC_CR_ADEN;
	if (!IO_WAIT(ADC1->ISR & ADC_ISR_ADRDY, 1000000u)) return 0;
	ADC1->CR |= ADC_CR_ADSTART;

	/* confirm a FULL first scan before init returns — the DMA transfer-complete
	 * flag (DMA1 LISR TCIF0) sets when NDTR reaches 0, i.e. every rank landed.
	 * NDTR != g_adc_n only proves ONE transfer, not the whole scan (codex emb#152).
	 * A timeout leaves first_ready 0: the checked reads fault, a degraded start. */
	g_adc_first_ready = IO_WAIT(DMA1->LISR & DMA_LISR_TCIF0, 2000000u);
	return 0;
}

unsigned int blob_io_adc_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || g_pt[ch].adc_slot < 0)
		return 0;
	/* one aligned 16-bit load from the DMA array — atomic on M7, never blocks */
	return (unsigned int)g_adc_dma[g_pt[ch].adc_slot];
}

int blob_io_adc_read_checked(int ch, unsigned int *val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || g_pt[ch].adc_slot < 0 || !val)
		return -1;
	if (!g_adc_first_ready) {
		/* the init-time bounded wait may have expired one loop before the first
		 * scan landed — latch lazily off the live TCIF so periodic reads recover
		 * (codex emb#152) rather than fault forever on a merely-slow converter. */
		if (!(DMA1->LISR & DMA_LISR_TCIF0)) return -1;
		g_adc_first_ready = 1;
	}
	*val = (unsigned int)g_adc_dma[g_pt[ch].adc_slot];
	return 0;
}

/* PWM: the pin -> (timer, channel, AF) matrix is a BOARD property (docs/io.md);
 * board_io_pwm_map fills it, weak-defaulting to "unsupported" so a pwm point on
 * a board without a map fails cfg LOUDLY rather than emitting no waveform (codex
 * emb#152). g_pwm_tim[ch] caches the resolved timer base for pwm_write. */
__attribute__((weak)) int board_io_pwm_map(int port, int pin, void **tim_base, int *chan, int *af, unsigned int *clk_hz) {
	(void)port; (void)pin; (void)tim_base; (void)chan; (void)af; (void)clk_hz;
	return -1; /* no PWM map on this board yet */
}
static TIM_TypeDef *g_pwm_tim[BLOB_IO_MAX];
static int g_pwm_ch[BLOB_IO_MAX];
static unsigned int g_pwm_arr[BLOB_IO_MAX]; /* period-1: duty = permille*(arr+1)/1000 */

/* enable the APBx timer clock gate for a timer base (codex emb#152: board clock
 * init leaves TIMx gates off). RM0399: APB2 = TIM1/8/15/16/17; APB1 = the rest. */
/* only the advanced (TIM1/8) and TIM15/16/17 timers implement BDTR/MOE; the
 * general-purpose TIM2-5/12-14 do not — writing MOE there is a stray store. */
static int tim_has_bdtr(TIM_TypeDef *t) {
	return t == TIM1 || t == TIM8 || t == TIM15 || t == TIM16 || t == TIM17;
}
/* timers already programmed by a pwm point, with their period-1, so a second
 * point on the SAME timer with a DIFFERENT carrier is rejected (it would silently
 * retune the first point — codex emb#152). */
static struct { TIM_TypeDef *t; int chan; unsigned int psc, arr; } g_tim_seen[BLOB_IO_MAX];
static int g_tim_seen_n;

static int tim_clock_enable(TIM_TypeDef *t) {
	if (t == TIM1) RCC->APB2ENR |= RCC_APB2ENR_TIM1EN;
	else if (t == TIM8) RCC->APB2ENR |= RCC_APB2ENR_TIM8EN;
	else if (t == TIM15) RCC->APB2ENR |= RCC_APB2ENR_TIM15EN;
	else if (t == TIM16) RCC->APB2ENR |= RCC_APB2ENR_TIM16EN;
	else if (t == TIM17) RCC->APB2ENR |= RCC_APB2ENR_TIM17EN;
	else if (t == TIM2) RCC->APB1LENR |= RCC_APB1LENR_TIM2EN;
	else if (t == TIM3) RCC->APB1LENR |= RCC_APB1LENR_TIM3EN;
	else if (t == TIM4) RCC->APB1LENR |= RCC_APB1LENR_TIM4EN;
	else if (t == TIM5) RCC->APB1LENR |= RCC_APB1LENR_TIM5EN;
	else if (t == TIM12) RCC->APB1LENR |= RCC_APB1LENR_TIM12EN;
	else if (t == TIM13) RCC->APB1LENR |= RCC_APB1LENR_TIM13EN;
	else if (t == TIM14) RCC->APB1LENR |= RCC_APB1LENR_TIM14EN;
	else return -1; /* an unrecognised timer base has no clock gate here (codex emb#152) */
	(void)RCC->APB2ENR;
	return 0;
}

/* program the timer + init duty for a pwm point, then mux the pad to AF. */
static int pwm_setup(int ch) {
	void *base = 0; int chan = 0, af = 0; unsigned int clk = 0;
	if (board_io_pwm_map((int)g_pt[ch].port, (int)g_pt[ch].pin, &base, &chan, &af, &clk) != 0
	    || !base || chan < 1 || chan > 4 || af < 0 || af > 15 || clk == 0u)
		return -1; /* bad map: reject before any register arithmetic (codex emb#152) */
	TIM_TypeDef *t = (TIM_TypeDef *)base;
	if (tim_clock_enable(t) != 0)
		return -1; /* no clock gate for this timer base */
	g_pwm_tim[ch] = t;
	g_pwm_ch[ch] = chan;

	/* accurate carrier: the period is total = clk / freq_hz timer counts. Keep
	 * PSC as small as possible (max duty resolution) with ARR <= 65535; the
	 * frequency is then clk / ((PSC+1)*(ARR+1)) = freq_hz when clk is a multiple
	 * of freq_hz (codex emb#152: the old fixed ARR=999 truncated the divisor). */
	unsigned int total = (g_pt[ch].freq_hz > 0u) ? (clk / (unsigned int)g_pt[ch].freq_hz) : 0u;
	if (total < 2u)
		return -1; /* freq too high for this clock: no usable period */
	unsigned int psc = 0u;
	while (total / (psc + 1u) > 65536u) psc++;
	unsigned int arr = total / (psc + 1u) - 1u;
	g_pwm_arr[ch] = arr;
	/* a shared timer must agree on the FULL carrier (psc AND arr — same arr with a
	 * different psc is a different frequency), and no two points may claim the same
	 * (timer, channel) (codex emb#152). */
	for (int k = 0; k < g_tim_seen_n; k++) {
		if (g_tim_seen[k].t == t) {
			if (g_tim_seen[k].chan == chan) return -1;                 /* duplicate (timer,channel) */
			if (g_tim_seen[k].psc != psc || g_tim_seen[k].arr != arr)  /* conflicting carrier */
				return -1;
			/* same carrier, other channel: record THIS channel too (so a later
			 * point on it is a detected duplicate), but don't reprogram PSC/ARR */
			g_tim_seen[g_tim_seen_n].t = t;
			g_tim_seen[g_tim_seen_n].chan = chan;
			g_tim_seen[g_tim_seen_n].psc = psc;
			g_tim_seen[g_tim_seen_n].arr = arr;
			g_tim_seen_n++;
			goto period_set;
		}
	}
	g_tim_seen[g_tim_seen_n].t = t;
	g_tim_seen[g_tim_seen_n].chan = chan;
	g_tim_seen[g_tim_seen_n].psc = psc;
	g_tim_seen[g_tim_seen_n].arr = arr;
	g_tim_seen_n++;
	t->PSC = psc;
	t->ARR = arr;
period_set:;
	volatile uint32_t *ccr = &t->CCR1 + (chan - 1);
	*ccr = (g_pt[ch].init * (arr + 1u)) / 1000u; /* init permille -> compare */
	if (chan == 1) t->CCMR1 = (t->CCMR1 & ~0xFFu) | (6u << 4) | (1u << 3); /* OC1M=110 PWM1, preload */
	else if (chan == 2) t->CCMR1 = (t->CCMR1 & ~0xFF00u) | (6u << 12) | (1u << 11);
	else if (chan == 3) t->CCMR2 = (t->CCMR2 & ~0xFFu) | (6u << 4) | (1u << 3);
	else t->CCMR2 = (t->CCMR2 & ~0xFF00u) | (6u << 12) | (1u << 11);
	t->CCER |= (1u << ((chan - 1) * 4));
	if (tim_has_bdtr(t)) t->BDTR |= TIM_BDTR_MOE; /* only where BDTR exists */
	t->EGR = TIM_EGR_UG;     /* latch PSC/ARR + the init CCR before the pad goes live */
	t->CR1 |= TIM_CR1_ARPE | TIM_CR1_CEN;

	/* pad -> AF only NOW, timer running at the init duty (no unconfigured-AF float) */
	GPIO_TypeDef *g = gpio(g_pt[ch].port);
	unsigned int p = g_pt[ch].pin;
	if (p < 8u) g->AFR[0] = (g->AFR[0] & ~(0xFu << (p * 4u))) | ((unsigned)af << (p * 4u));
	else g->AFR[1] = (g->AFR[1] & ~(0xFu << ((p - 8u) * 4u))) | ((unsigned)af << ((p - 8u) * 4u));
	g->MODER = (g->MODER & ~(3u << (p * 2u))) | (2u << (p * 2u)); /* 10 = AF */
	return 0;
}

void blob_io_pwm_write(int ch, unsigned int permille) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || g_pt[ch].kind != IO_PWM
	    || !g_pwm_tim[ch])
		return;
	if (permille > 1000u) permille = 1000u;
	TIM_TypeDef *t = g_pwm_tim[ch];
	volatile uint32_t *ccr = &t->CCR1 + (g_pwm_ch[ch] - 1);
	*ccr = (permille * (g_pwm_arr[ch] + 1u)) / 1000u; /* permille -> compare at this period */
}

void blob_io_close(void) {
	/* stop the free-running ADC/DMA and reset the scan bookkeeping so a re-declare
	 * assigns fresh slots (codex emb#152: g_adc_n leaked, ghost ranks accrued).
	 * Pins keep their configured mode/level — yanking an actuator back to analog
	 * on close would be a glitch, not a cleanup. */
	DMA1_Stream0->CR &= ~DMA_SxCR_EN;
	if (ADC1->CR & ADC_CR_ADSTART) {
		ADC1->CR |= ADC_CR_ADSTP;
		(void)IO_WAIT(!(ADC1->CR & ADC_CR_ADSTP), 100000u);
	}
	if (ADC1->CR & ADC_CR_ADEN) {
		ADC1->CR |= ADC_CR_ADDIS; /* H7 calibration needs ADEN=0 on the next init */
		(void)IO_WAIT(!(ADC1->CR & ADC_CR_ADEN), 100000u);
	}
	DMA1->LIFCR = DMA_LIFCR_CTCIF0; /* drop the scan-complete flag on close too */
	g_adc_n = 0;
	g_adc_first_ready = 0;
	g_tim_seen_n = 0;
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		g_pt[i].configured = 0;
		g_pwm_tim[i] = 0;
	}
}
