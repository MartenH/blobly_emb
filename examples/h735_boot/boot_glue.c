/* h735_boot glue — the C half of the boot manager: handshake cells, the jump,
 * the reset, and the 0x29 RNG source (boards/h735dk/flash.c holds the FlashOps).
 * The jump runs from NEAR-RESET state by design (docs/bootloader.md): nothing
 * is enabled when the happy path takes it, so there is nothing to deinit.
 * Verbatim twin of examples/h755_boot/boot_glue.c — the STM32H7 RNG IP, the
 * SRAM4 bootcell, and the Cortex-M7 VTOR/reset sequences are identical across
 * H72x/H73x and H74x/H75x. */
#include <stdint.h>
#include "bootmap.h"

int bflash_erase(uint32_t addr, uint32_t size);
int bflash_program(uint32_t addr, const uint8_t *data, uint32_t len);
int bflash_read(uint32_t addr, uint8_t *out, uint32_t len);

/* bootcell_take_request: consume (read + clear) a pending programming request. */
uint32_t bootcell_take_request(void) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
	if (c[0] != BOOTCELL_REQ_MAGIC) return 0;
	c[0] = 0;
	return 1;
}

void bootcell_set_info(uint32_t reason) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_INFO_ADDR;
	c[1] = reason;
	c[0] = BOOTCELL_INFO_MAGIC;
}

/* boot_jump_app: VTOR -> the app's vector table, MSP from its word 0, jump to
 * its reset vector. Never returns. */
void boot_jump_app(void) {
	volatile uint32_t *vt = (volatile uint32_t *)APP_VECTORS;
	*(volatile uint32_t *)0xE000ED08u = APP_VECTORS; /* SCB->VTOR */
	__asm__ volatile("dsb; isb");
	__asm__ volatile("msr msp, %0" : : "r"(vt[0]));
	((void (*)(void))vt[1])();
	for (;;) {
	}
}

/* boot_sys_reset: NVIC_SystemReset — AIRCR key + SYSRESETREQ. */
void boot_sys_reset(void) {
	__asm__ volatile("dsb");
	*(volatile uint32_t *)0xE000ED0Cu = (0x5FAu << 16) | (1u << 2);
	for (;;) {
	}
}

/* board_rng — the 0x29 challenge source (REQ-BOOT-016): the STM32H7 true RNG.
 * Kernel clock = HSI48 (RNGSEL 00). Bounded polling so a dead RNG can't hang the
 * boot — it returns 0 and the 0x29 request answers conditionsNotCorrect. */
#define RCC_CR_R       (*(volatile uint32_t *)0x58024400u)
#define RCC_D2CCIP2R_R (*(volatile uint32_t *)0x58024454u)
#define RCC_AHB2ENR_R  (*(volatile uint32_t *)0x580244DCu)
#define RNG_CR_R       (*(volatile uint32_t *)0x48021800u)
#define RNG_SR_R       (*(volatile uint32_t *)0x48021804u)
#define RNG_DR_R       (*(volatile uint32_t *)0x48021808u)

static int g_rng_ready = 0;
static int rng_setup(void) {
	RCC_CR_R |= (1u << 12); /* HSI48ON */
	for (uint32_t t = 0; !(RCC_CR_R & (1u << 13)); t++)
		if (t > 2000000u) return 0; /* HSI48RDY never came */
	RCC_D2CCIP2R_R &= ~(3u << 8); /* RNGSEL = 00 = HSI48 */
	RCC_AHB2ENR_R |= (1u << 6);    /* RNG kernel+bus clock */
	(void)RCC_AHB2ENR_R;
	RNG_CR_R = (1u << 2); /* RNGEN, clock-error detection on */
	g_rng_ready = 1;
	return 1;
}

int board_rng(uint8_t *out, int n) {
	if (!g_rng_ready && !rng_setup()) return 0;
	int i = 0;
	while (i < n) {
		uint32_t t = 0;
		while (!(RNG_SR_R & 1u)) { /* DRDY */
			if (++t > 200000u) return 0;
		}
		if (RNG_SR_R & 0x6u) { /* seed/clock error */
			RNG_SR_R = 0;
			return 0;
		}
		uint32_t w = RNG_DR_R;
		for (int b = 0; b < 4 && i < n; b++, i++)
			out[i] = (uint8_t)(w >> (8 * b));
	}
	return 1;
}
