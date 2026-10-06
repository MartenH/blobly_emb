/* STM32H735G-DK LCD bring-up — register-level, no HAL.
 *
 * Pins, panel timing and pixel clock follow ST's stm32h735g-dk BSP (stm32h735g_discovery_lcd.c,
 * the RK043FN48H component driver) value for value, including its back-porch arithmetic: the
 * active width the LTDC is given is 11 pixels wider than the layer, and the panel shows the
 * layer's 480. The D-cache is off on this board (board.c), so CPU writes to a framebuffer
 * reach the LTDC without cache maintenance.
 */
#include <stm32h735xx.h>
#include "board.h"
#include "lcd.h"

#define HSYNC 41u
#define HBP   13u
#define HFP   32u
#define VSYNC 10u
#define VBP   2u
#define VFP   2u

static void lcd_fault(void) {
	for (;;) {
	}
}

/* pin_af: one pad to alternate function `af`, push-pull, high speed, no pull. */
static void pin_af(GPIO_TypeDef *g, uint32_t pin, uint32_t af) {
	g->MODER = (g->MODER & ~(3u << (pin * 2u))) | (2u << (pin * 2u));
	g->OTYPER &= ~(1u << pin);
	g->OSPEEDR = (g->OSPEEDR & ~(3u << (pin * 2u))) | (2u << (pin * 2u));
	g->PUPDR &= ~(3u << (pin * 2u));
	g->AFR[pin >> 3] = (g->AFR[pin >> 3] & ~(0xFu << ((pin & 7u) * 4u))) | (af << ((pin & 7u) * 4u));
}

/* pin_out: one pad to a push-pull output driven to `level`. */
static void pin_out(GPIO_TypeDef *g, uint32_t pin, int level) {
	g->BSRR = level ? (1u << pin) : (1u << (pin + 16u));
	g->MODER = (g->MODER & ~(3u << (pin * 2u))) | (1u << (pin * 2u));
	g->OTYPER &= ~(1u << pin);
	g->PUPDR &= ~(3u << (pin * 2u));
}

/* The LTDC's 28 signals: AF14 except PA8 (AF13) and PH4 (AF9). */
static void lcd_pins(void) {
	static const struct { GPIO_TypeDef *g; uint16_t pins; } af14[] = {
		{ GPIOA, (1u << 3) | (1u << 4) | (1u << 6) },
		{ GPIOB, (1u << 0) | (1u << 1) | (1u << 8) | (1u << 9) },
		{ GPIOC, (1u << 6) | (1u << 7) },
		{ GPIOD, (1u << 0) | (1u << 3) | (1u << 6) },
		{ GPIOE, (1u << 0) | (1u << 1) | (1u << 11) | (1u << 12) | (1u << 15) },
		{ GPIOG, (1u << 7) | (1u << 14) },
		{ GPIOH, (1u << 3) | (1u << 8) | (1u << 9) | (1u << 10) | (1u << 11) | (1u << 15) },
	};
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOAEN | RCC_AHB4ENR_GPIOBEN | RCC_AHB4ENR_GPIOCEN | RCC_AHB4ENR_GPIODEN
	              | RCC_AHB4ENR_GPIOEEN | RCC_AHB4ENR_GPIOGEN | RCC_AHB4ENR_GPIOHEN;
	(void)RCC->AHB4ENR;
	for (unsigned i = 0; i < sizeof af14 / sizeof af14[0]; i++) {
		for (uint32_t p = 0; p < 16u; p++) {
			if (af14[i].pins & (1u << p)) pin_af(af14[i].g, p, 14u);
		}
	}
	pin_af(GPIOA, 8u, 13u);
	pin_af(GPIOH, 4u, 9u);
	/* the BSP's panel controls: DISP_EN (PE13) low, DISP_CTRL (PD10) high, backlight (PG15) on */
	pin_out(GPIOE, 13u, 0);
	pin_out(GPIOD, 10u, 1);
	pin_out(GPIOG, 15u, 1);
}

/* PLL3_R = 25 MHz / 5 * 160 / 83 = 9.64 MHz, the LTDC's kernel clock. */
static void lcd_clock(void) {
	RCC->CR &= ~RCC_CR_PLL3ON;
	for (uint32_t t = 0; RCC->CR & RCC_CR_PLL3RDY; t++) {
		if (t >= 4000000u) lcd_fault();
	}
	RCC->PLLCKSELR = (RCC->PLLCKSELR & ~RCC_PLLCKSELR_DIVM3_Msk) | (5u << RCC_PLLCKSELR_DIVM3_Pos);
	RCC->PLLCFGR = (RCC->PLLCFGR & ~(RCC_PLLCFGR_PLL3RGE_Msk | RCC_PLLCFGR_PLL3VCOSEL | RCC_PLLCFGR_PLL3FRACEN
	                                 | RCC_PLLCFGR_DIVP3EN | RCC_PLLCFGR_DIVQ3EN))
	             | RCC_PLLCFGR_PLL3RGE_1 /* 0b10: 4-8 MHz ref */ | RCC_PLLCFGR_DIVR3EN;
	RCC->PLL3DIVR = ((160u - 1u) << RCC_PLL3DIVR_N3_Pos) | ((2u - 1u) << RCC_PLL3DIVR_P3_Pos)
	              | ((2u - 1u) << RCC_PLL3DIVR_Q3_Pos) | ((83u - 1u) << RCC_PLL3DIVR_R3_Pos);
	RCC->CR |= RCC_CR_PLL3ON;
	for (uint32_t t = 0; (RCC->CR & RCC_CR_PLL3RDY) == 0u; t++) {
		if (t >= 4000000u) lcd_fault();
	}
}

void lcd_init(const void *fb) {
	lcd_pins();
	uint64_t t0 = board_now_us();
	while (board_now_us() - t0 < 40000u) {
	}
	lcd_clock();

	RCC->APB3ENR |= RCC_APB3ENR_LTDCEN;
	(void)RCC->APB3ENR;
	RCC->APB3RSTR |= RCC_APB3RSTR_LTDCRST;
	RCC->APB3RSTR &= ~RCC_APB3RSTR_LTDCRST;

	const uint32_t ahbp = HSYNC + (HBP - 11u) - 1u;
	const uint32_t avbp = VSYNC + VBP - 1u;
	LTDC->SSCR = ((HSYNC - 1u) << 16) | (VSYNC - 1u);
	LTDC->BPCR = (ahbp << 16) | avbp;
	LTDC->AWCR = ((HSYNC + LCD_W + HBP - 1u) << 16) | (VSYNC + LCD_H + VBP - 1u);
	LTDC->TWCR = ((HSYNC + LCD_W + (HBP - 11u) + HFP - 1u) << 16) | (VSYNC + LCD_H + VBP + VFP - 1u);
	LTDC->GCR = 0u; /* HSYNC/VSYNC/DE active low, pixel clock not inverted */
	LTDC->BCCR = 0u;

	LTDC_Layer1->WHPCR = ((LCD_W + ahbp) << 16) | (ahbp + 1u);
	LTDC_Layer1->WVPCR = ((LCD_H + avbp) << 16) | (avbp + 1u);
	LTDC_Layer1->PFCR = 2u; /* RGB565 */
	LTDC_Layer1->CACR = 255u;
	LTDC_Layer1->DCCR = 0u;
	LTDC_Layer1->BFCR = (6u << 8) | 7u; /* pixel alpha x constant alpha */
	LTDC_Layer1->CFBAR = (uint32_t)fb;
	LTDC_Layer1->CFBLR = ((LCD_W * 2u) << 16) | (LCD_W * 2u + 7u);
	LTDC_Layer1->CFBLNR = LCD_H;
	LTDC_Layer1->CR = LTDC_LxCR_LEN;
	LTDC->SRCR = LTDC_SRCR_IMR;
	LTDC->GCR |= LTDC_GCR_LTDCEN;
}

void lcd_show(const void *fb) {
	LTDC_Layer1->CFBAR = (uint32_t)fb;
	LTDC->SRCR = LTDC_SRCR_VBR;
}

int lcd_shown(void) {
	return (LTDC->SRCR & LTDC_SRCR_VBR) == 0u;
}
