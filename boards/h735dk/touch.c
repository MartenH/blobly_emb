/* STM32H735G-DK touch — I2C4 master (register-level) + GT911 / FT5336 readers.
 *
 * I2C4 runs from its reset kernel clock, PCLK4 = 137.5 MHz (board.c). TIMINGR for ~100 kHz:
 * PRESC 15 (116 ns), SCLL 42, SCLH 34, SDADEL 2, SCLDEL 4. Every wait is bounded; a
 * controller that stops answering reads as "not touched", never as a hang.
 */
#include <stm32h735xx.h>
#include "board.h"
#include "lcd.h"
#include "touch.h"

#define I2C_TIMINGR ((15u << 28) | (4u << 20) | (2u << 16) | (34u << 8) | 42u)
#define I2C_WAIT_US 2000u

static int g_chip;
static uint8_t g_addr;
static int g_max_x = LCD_W, g_max_y = LCD_H;
static int g_down, g_x, g_y;
volatile int touch_raw_x, touch_raw_y;
/* bench diagnostics, read over SWD: both chips' ID bytes, and how polls went (ok, failed,
 * reports with a finger down, the last FT5336 report) */
volatile uint8_t touch_gt_id[4], touch_ft_id;
volatile uint32_t touch_polls_ok, touch_polls_failed, touch_downs;
volatile uint8_t touch_last[5];

/* wait for `flag` in ISR; 0 on NACK or timeout (and the bus is left stopped). */
static int i2c_wait(uint32_t flag) {
	uint64_t t0 = board_now_us();
	while ((I2C4->ISR & flag) == 0u) {
		if (I2C4->ISR & I2C_ISR_NACKF) {
			I2C4->ICR = I2C_ICR_NACKCF;
			while ((I2C4->ISR & I2C_ISR_STOPF) == 0u && board_now_us() - t0 < I2C_WAIT_US) {
			}
			I2C4->ICR = I2C_ICR_STOPCF;
			return 0;
		}
		if (board_now_us() - t0 >= I2C_WAIT_US) {
			I2C4->CR1 &= ~I2C_CR1_PE; /* software reset: drop whatever the bus was doing */
			(void)I2C4->CR1;
			I2C4->CR1 |= I2C_CR1_PE;
			return 0;
		}
	}
	return 1;
}

/* i2c_xfer: write `nw` bytes, then (if nr) read `nr` bytes with a repeated start. */
static int i2c_xfer(uint8_t addr, const uint8_t *w, uint32_t nw, uint8_t *r, uint32_t nr) {
	I2C4->ICR = I2C_ICR_STOPCF | I2C_ICR_NACKCF;
	I2C4->CR2 = ((uint32_t)addr << 1) | (nw << I2C_CR2_NBYTES_Pos) | (nr ? 0u : I2C_CR2_AUTOEND) | I2C_CR2_START;
	for (uint32_t i = 0; i < nw; i++) {
		if (!i2c_wait(I2C_ISR_TXIS)) return 0;
		I2C4->TXDR = w[i];
	}
	if (nr) {
		if (!i2c_wait(I2C_ISR_TC)) return 0;
		I2C4->CR2 = ((uint32_t)addr << 1) | I2C_CR2_RD_WRN | (nr << I2C_CR2_NBYTES_Pos) | I2C_CR2_AUTOEND
		          | I2C_CR2_START;
		for (uint32_t i = 0; i < nr; i++) {
			if (!i2c_wait(I2C_ISR_RXNE)) return 0;
			r[i] = (uint8_t)I2C4->RXDR;
		}
	}
	if (!i2c_wait(I2C_ISR_STOPF)) return 0;
	I2C4->ICR = I2C_ICR_STOPCF;
	return 1;
}

static int gt_read(uint16_t reg, uint8_t *r, uint32_t n) {
	uint8_t w[2] = { (uint8_t)(reg >> 8), (uint8_t)reg };
	return i2c_xfer(g_addr, w, 2, r, n);
}

static void i2c4_init(void) {
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOFEN;
	(void)RCC->AHB4ENR;
	for (uint32_t p = 14; p <= 15; p++) { /* AF4, open drain, pull-up */
		GPIOF->MODER = (GPIOF->MODER & ~(3u << (p * 2u))) | (2u << (p * 2u));
		GPIOF->OTYPER |= 1u << p;
		GPIOF->OSPEEDR = (GPIOF->OSPEEDR & ~(3u << (p * 2u))) | (1u << (p * 2u));
		GPIOF->PUPDR = (GPIOF->PUPDR & ~(3u << (p * 2u))) | (1u << (p * 2u));
		GPIOF->AFR[1] = (GPIOF->AFR[1] & ~(0xFu << ((p - 8u) * 4u))) | (4u << ((p - 8u) * 4u));
	}
	RCC->APB4ENR |= RCC_APB4ENR_I2C4EN;
	(void)RCC->APB4ENR;
	RCC->APB4RSTR |= RCC_APB4RSTR_I2C4RST;
	RCC->APB4RSTR &= ~RCC_APB4RSTR_I2C4RST;
	I2C4->CR1 = 0u;
	I2C4->TIMINGR = I2C_TIMINGR;
	I2C4->CR1 = I2C_CR1_PE;
}

int touch_init(void) {
	i2c4_init();
	static const uint8_t gt_addrs[] = { 0x5Du, 0x14u };
	for (unsigned i = 0; i < sizeof gt_addrs; i++) {
		uint8_t id[4];
		g_addr = gt_addrs[i];
		int ok = gt_read(0x8140u, id, 4);
		if (ok && i == 0) for (int k = 0; k < 4; k++) touch_gt_id[k] = id[k];
		if (ok && id[0] == '9' && id[1] == '1' && id[2] == '1') {
			uint8_t res[4];
			if (gt_read(0x8048u, res, 4)) { /* the configured X/Y resolution */
				int mx = res[0] | (res[1] << 8), my = res[2] | (res[3] << 8);
				if (mx > 0 && my > 0) { g_max_x = mx; g_max_y = my; }
			}
			return g_chip = TOUCH_GT911;
		}
	}
	uint8_t reg = 0xA8u, id = 0; /* FT5336 chip vendor id: 0x51 */
	g_addr = 0x38u;
	if (i2c_xfer(g_addr, &reg, 1, &id, 1)) {
		touch_ft_id = id;
		return g_chip = TOUCH_FT5336;
	}
	return g_chip = TOUCH_NONE;
}

int touch_read(int *x, int *y) {
	if (g_chip == TOUCH_GT911) {
		uint8_t st;
		if (!gt_read(0x814Eu, &st, 1)) {
			g_down = 0;
		} else if (st & 0x80u) { /* a fresh report: count in the low nibble */
			uint8_t p[4];
			g_down = (st & 0x0Fu) != 0u && gt_read(0x8150u, p, 4);
			if (g_down) {
				touch_raw_x = p[0] | (p[1] << 8);
				touch_raw_y = p[2] | (p[3] << 8);
				g_x = touch_raw_x * LCD_W / g_max_x;
				g_y = touch_raw_y * LCD_H / g_max_y;
			}
			uint8_t clr[3] = { 0x81u, 0x4Eu, 0u };
			(void)i2c_xfer(g_addr, clr, 3, 0, 0);
		}
	} else if (g_chip == TOUCH_FT5336) {
		uint8_t reg = 0x02u, p[5] = { 0 };
		int ok = i2c_xfer(g_addr, &reg, 1, p, 5);
		if (ok) {
			touch_polls_ok++;
			for (int k = 0; k < 5; k++) touch_last[k] = p[k];
		} else {
			touch_polls_failed++;
		}
		/* TD_STATUS: 1..5 fingers. Idle, this panel's FT5336 reports 0xFF in every byte, so a
		 * count past 5 is "no touch" (as ST's ft5336 driver reads it), not 15 fingers. */
		uint8_t n = p[0] & 0x0Fu;
		g_down = ok && n >= 1u && n <= 5u;
		if (g_down) touch_downs++;
		if (g_down) {
			touch_raw_x = ((p[1] & 0x0F) << 8) | p[2];
			touch_raw_y = ((p[3] & 0x0F) << 8) | p[4];
			/* this panel's FT5336 runs portrait: its X is the panel's Y and its Y the panel's X
			 * (bench: a press on the right-hand button read raw 160, 393) */
			g_x = touch_raw_y;
			g_y = touch_raw_x;
		}
	} else {
		g_down = 0;
	}
	if (g_x >= LCD_W) g_x = LCD_W - 1;
	if (g_y >= LCD_H) g_y = LCD_H - 1;
	*x = g_x;
	*y = g_y;
	return g_down;
}
