/* h755_boot glue — the C half of the boot manager: handshake cells, the jump,
 * the reset, and the FlashOps wrappers (boards/h755zi/flash.c).
 * The jump runs from NEAR-RESET state by design (docs/bootloader.md): nothing
 * is enabled when the happy path takes it, so there is nothing to deinit. */
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
