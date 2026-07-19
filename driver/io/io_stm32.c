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
#include <stm32h7xx.h> /* CMSIS family dispatcher (build sets -DSTM32H735xx / -DSTM32H755xx); no HAL */

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
			/* AF push-pull for the timer channel. The AF NUMBER (which TIMx) is a
			 * pad property — the boards layer owns the pin->(timer,channel,AF)
			 * matrix (docs/io.md); this dry path muxes AF and the timer setup
			 * below is the bench-completion point. */
			g->MODER = (g->MODER & ~(3u << (p * 2u))) | (2u << (p * 2u)); /* 10 = AF */
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
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (g_pt[i].configured && g_pt[i].kind == IO_PWM) {
			if (pwm_setup(i) != 0)
				return -1; /* no board pin->timer map: fail LOUDLY, never a dead pin */
		}
	}
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
	RCC->AHB1ENR |= RCC_AHB1ENR_ADC12EN | RCC_AHB1ENR_DMA1EN;
	(void)RCC->AHB1ENR;

	/* exit deep-power-down, enable the regulator, let the LDO settle */
	ADC1->CR &= ~ADC_CR_DEEPPWD;
	ADC1->CR |= ADC_CR_ADVREGEN;
	for (volatile int w = 0; w < 20000; w++) { } /* > 10 us LDO startup */

	/* calibrate (single-ended) — BOUNDED: a dead kernel clock must not hang */
	ADC1->CR &= ~ADC_CR_ADCALDIF;
	ADC1->CR |= ADC_CR_ADCAL;
	if (!IO_WAIT(!(ADC1->CR & ADC_CR_ADCAL), 1000000u)) return -1;

	/* 12-bit right-aligned; continuous + DMA circular (DMNGT=11) */
	ADC1->CFGR = ADC_CFGR_CONT | ADC_CFGR_DMNGT_0 | ADC_CFGR_DMNGT_1;

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
	}
	ADC1->SQR1 = sqr[0];
	ADC1->SQR2 = sqr[1];
	ADC1->SQR3 = sqr[2];
	ADC1->SQR4 = sqr[3];

	/* DMA1 Stream0: ADC1->DR -> g_adc_dma, 16-bit, circular, mem-increment */
	DMA1_Stream0->CR = 0;
	if (!IO_WAIT(!(DMA1_Stream0->CR & DMA_SxCR_EN), 100000u)) return -1;
	DMA1_Stream0->PAR = (uint32_t)(&ADC1->DR);
	DMA1_Stream0->M0AR = (uint32_t)g_adc_dma;
	DMA1_Stream0->NDTR = (uint32_t)g_adc_n;
	DMAMUX1_Channel0->CCR = 9u; /* request 9 = adc1 (RM0399 DMAMUX table) */
	DMA1_Stream0->CR = DMA_SxCR_MINC | DMA_SxCR_CIRC |
	                   (1u << DMA_SxCR_MSIZE_Pos) | (1u << DMA_SxCR_PSIZE_Pos) |
	                   DMA_SxCR_EN;

	/* enable + start — BOUNDED ADRDY wait */
	ADC1->ISR = ADC_ISR_ADRDY;
	ADC1->CR |= ADC_CR_ADEN;
	if (!IO_WAIT(ADC1->ISR & ADC_ISR_ADRDY, 1000000u)) return -1;
	ADC1->CR |= ADC_CR_ADSTART;

	/* confirm the FIRST full scan actually landed before init returns, so the
	 * boot publish reads a real count, not the zero-initialised buffer (codex
	 * emb#152, docs/io.md startup). NDTR reloads to g_adc_n after each scan; it
	 * having decremented below g_adc_n proves DMA is moving. */
	g_adc_first_ready = IO_WAIT(DMA1_Stream0->NDTR != (uint32_t)g_adc_n
	                            || (DMA1_Stream0->CR & DMA_SxCR_EN) == 0, 2000000u)
	                    && (DMA1_Stream0->CR & DMA_SxCR_EN);
	return g_adc_first_ready ? 0 : -1;
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
	if (!g_adc_first_ready) return -1; /* no real conversion yet: boot must not fabricate */
	*val = (unsigned int)g_adc_dma[g_pt[ch].adc_slot];
	return 0;
}

/* PWM: the pin -> (timer, channel, AF) matrix is a BOARD property (docs/io.md);
 * board_io_pwm_map fills it, weak-defaulting to "unsupported" so a pwm point on
 * a board without a map fails cfg LOUDLY rather than emitting no waveform (codex
 * emb#152). g_pwm_tim[ch] caches the resolved timer base for pwm_write. */
__attribute__((weak)) int board_io_pwm_map(int port, int pin, void **tim_base, int *chan, int *af) {
	(void)port; (void)pin; (void)tim_base; (void)chan; (void)af;
	return -1; /* no PWM map on this board yet */
}
static TIM_TypeDef *g_pwm_tim[BLOB_IO_MAX];
static int g_pwm_ch[BLOB_IO_MAX];

/* apply the init duty + program the timer for a pwm point, called from init. */
static int pwm_setup(int ch) {
	void *base = 0; int chan = 0, af = 0;
	if (board_io_pwm_map((int)g_pt[ch].port, (int)g_pt[ch].pin, &base, &chan, &af) != 0 || !base)
		return -1;
	TIM_TypeDef *t = (TIM_TypeDef *)base;
	g_pwm_tim[ch] = t;
	g_pwm_ch[ch] = chan;
	/* AFR on the pad for the mapped timer AF number */
	GPIO_TypeDef *g = gpio(g_pt[ch].port);
	unsigned int p = g_pt[ch].pin;
	if (p < 8u) g->AFR[0] = (g->AFR[0] & ~(0xFu << (p * 4u))) | ((unsigned)af << (p * 4u));
	else g->AFR[1] = (g->AFR[1] & ~(0xFu << ((p - 8u) * 4u))) | ((unsigned)af << ((p - 8u) * 4u));
	/* carrier: ARR = 1000 (a permille maps 1:1 to CCR), PSC from the timer clock.
	 * The kernel timer clock is board-known; a bench pass sets PSC for freq_hz.
	 * DRY: ARR=999 gives 1000 steps; PSC left 0 (bench sets it for the real Hz). */
	t->PSC = 0;
	t->ARR = 999u;
	volatile uint32_t *ccr = &t->CCR1 + (chan - 1);
	*ccr = (g_pt[ch].init * 1000u) / 1000u; /* init permille -> compare */
	/* PWM mode 1 on the channel (CCMR), enable output (CCER), main output (BDTR), CR1 */
	if (chan == 1) t->CCMR1 = (t->CCMR1 & ~0xFFu) | (6u << 4) | (1u << 3); /* OC1M=110, preload */
	else if (chan == 2) t->CCMR1 = (t->CCMR1 & ~0xFF00u) | (6u << 12) | (1u << 11);
	else if (chan == 3) t->CCMR2 = (t->CCMR2 & ~0xFFu) | (6u << 4) | (1u << 3);
	else t->CCMR2 = (t->CCMR2 & ~0xFF00u) | (6u << 12) | (1u << 11);
	t->CCER |= (1u << ((chan - 1) * 4));
	t->BDTR |= TIM_BDTR_MOE; /* advanced timers need MOE; harmless on basic ones */
	t->CR1 |= TIM_CR1_ARPE | TIM_CR1_CEN;
	t->EGR = TIM_EGR_UG; /* latch PSC/ARR */
	return 0;
}

void blob_io_pwm_write(int ch, unsigned int permille) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || g_pt[ch].kind != IO_PWM
	    || !g_pwm_tim[ch])
		return;
	if (permille > 1000u) permille = 1000u;
	TIM_TypeDef *t = g_pwm_tim[ch];
	volatile uint32_t *ccr = &t->CCR1 + (g_pwm_ch[ch] - 1);
	*ccr = permille; /* ARR=999 so permille maps 1:1 to the compare */
}

void blob_io_close(void) {
	/* stop the free-running ADC/DMA and reset the scan bookkeeping so a re-declare
	 * assigns fresh slots (codex emb#152: g_adc_n leaked, ghost ranks accrued).
	 * Pins keep their configured mode/level — yanking an actuator back to analog
	 * on close would be a glitch, not a cleanup. */
	DMA1_Stream0->CR &= ~DMA_SxCR_EN;
	ADC1->CR |= ADC_CR_ADSTP;
	g_adc_n = 0;
	g_adc_first_ready = 0;
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		g_pt[i].configured = 0;
		g_pwm_tim[i] = 0;
	}
}
