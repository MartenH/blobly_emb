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
static volatile unsigned short g_adc_dma[BLOB_IO_MAX];
static int g_adc_n; /* number of ADC points (== ranked length of the scan) */

/* pin -> ADC1 channel (STM32H7 ADC1, RM0399 tbl). Small map: bench-extend as
 * points need pads. -1 = not an ADC1-capable pad on this map. */
static void adc_dma_start(void);
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
		if (pin <= 5) return (int)(10u + pin); /* PC0..PC5 -> IN10..IN15 */
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
	if (g_adc_n > 0)
		adc_dma_start();
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


/* adc_dma_start: ADC1 in continuous scan over the configured channels, results
 * DMA'd circularly into g_adc_dma — free-running, no interrupts (REQ-IO-018).
 * DRY-CODED from RM0399: clock + deep-power-down exit + calibration + the
 * regular-sequence ranks + DMA1 stream config. Every register here is on the
 * P2 bench checklist. */
static void adc_dma_start(void) {
	/* 1. kernel + bus clocks: ADC on AHB1, DMA1 on AHB1 */
	RCC->AHB1ENR |= RCC_AHB1ENR_ADC12EN | RCC_AHB1ENR_DMA1EN;
	(void)RCC->AHB1ENR;

	/* 2. exit deep-power-down, enable the voltage regulator, wait for it */
	ADC1->CR &= ~ADC_CR_DEEPPWD;
	ADC1->CR |= ADC_CR_ADVREGEN;
	for (volatile int w = 0; w < 10000; w++) { } /* > 10 us LDO startup */

	/* 3. calibrate (single-ended), wait for completion */
	ADC1->CR &= ~ADC_CR_ADCALDIF;
	ADC1->CR |= ADC_CR_ADCAL;
	while (ADC1->CR & ADC_CR_ADCAL) { }

	/* 4. 12-bit, right-aligned; continuous + DMA circular */
	ADC1->CFGR = ADC_CFGR_CONT | ADC_CFGR_DMNGT_0 | ADC_CFGR_DMNGT_1; /* DMNGT=11: DMA circular */

	/* 5. the regular sequence: g_adc_n ranks, in cfg order (the slot order the
	 * DMA array mirrors). SQR1[3:0] = length-1; ranks pack 6/register. */
	unsigned int sqr[4] = { 0, 0, 0, 0 };
	sqr[0] = (unsigned int)(g_adc_n - 1); /* L field */
	int rank = 1;
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (!g_pt[i].configured || g_pt[i].kind != IO_ADC) continue;
		int slot = g_pt[i].adc_slot;      /* rank position == DMA slot */
		int r = slot + 1;                 /* SQ1 is rank 1 */
		int reg = r / 6, pos = (r % 6) * 6 + 5 - 5; /* 5-bit SQx fields, 6 per reg after SQR1 offset */
		/* SQR1: SQ1..SQ4 at bits 6,12,18,24; SQR2..: 6 per reg at 0,6,12,... */
		if (r <= 4) { sqr[0] |= (g_pt[i].adc_ch & 0x1Fu) << (6 + (r - 1) * 6); }
		else { int rr = r - 5; reg = 1 + rr / 6; pos = (rr % 6) * 6; sqr[reg] |= (g_pt[i].adc_ch & 0x1Fu) << pos; }
		/* long sample time for the pot's source impedance (SMPR: 3 bits/ch) */
		if (g_pt[i].adc_ch < 10) ADC1->SMPR1 |= (7u << (g_pt[i].adc_ch * 3u));
		else ADC1->SMPR2 |= (7u << ((g_pt[i].adc_ch - 10u) * 3u));
		(void)rank; rank++;
	}
	ADC1->SQR1 = sqr[0];
	ADC1->SQR2 = sqr[1];
	ADC1->SQR3 = sqr[2];
	ADC1->SQR4 = sqr[3];

	/* 6. DMA1 Stream0: peripheral ADC1->DR -> g_adc_dma, 16-bit, circular, incr mem */
	DMA1_Stream0->CR = 0;
	while (DMA1_Stream0->CR & DMA_SxCR_EN) { }
	DMA1_Stream0->PAR = (uint32_t)(&ADC1->DR);
	DMA1_Stream0->M0AR = (uint32_t)g_adc_dma;
	DMA1_Stream0->NDTR = (uint32_t)g_adc_n;
	DMAMUX1_Channel0->CCR = 9u; /* request 9 = adc1 (RM0399 DMAMUX table) */
	DMA1_Stream0->CR = DMA_SxCR_MINC | DMA_SxCR_CIRC |
	                   (1u << DMA_SxCR_MSIZE_Pos) | (1u << DMA_SxCR_PSIZE_Pos) | /* 16-bit both */
	                   DMA_SxCR_EN;

	/* 7. enable + start the ADC */
	ADC1->ISR = ADC_ISR_ADRDY;
	ADC1->CR |= ADC_CR_ADEN;
	while (!(ADC1->ISR & ADC_ISR_ADRDY)) { }
	ADC1->CR |= ADC_CR_ADSTART;
}

unsigned int blob_io_adc_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || g_pt[ch].adc_slot < 0)
		return 0;
	/* one aligned 16-bit load from the DMA array — atomic on M7, never blocks */
	return (unsigned int)g_adc_dma[g_pt[ch].adc_slot];
}

void blob_io_pwm_write(int ch, unsigned int permille) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || g_pt[ch].kind != IO_PWM)
		return;
	if (permille > 1000u) permille = 1000u;
	/* DRY: set the bound timer channel's compare = permille * (ARR+1) / 1000.
	 * The (timer, channel, ARR) come from the boards pin-timer map at bench
	 * time; until then this is the shape, not a live register write. */
	(void)permille;
}

void blob_io_close(void) {
	/* forget the table only — pins keep their configured mode and level: yanking
	 * an actuator back to analog on close would be a glitch, not a cleanup. */
	for (int i = 0; i < BLOB_IO_MAX; i++)
		g_pt[i].configured = 0;
}
