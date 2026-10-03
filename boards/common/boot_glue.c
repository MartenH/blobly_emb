/* boot_glue.c — the C half of the boot manager image (boot/target/main.v), the same for every board
 * and node: what the V program asks is answered from the board's bootmap.h (flash layout, cells,
 * through bootcell.h) and the node's gen/boot_gen.h (bus, ids, flow control, keys — written by
 * loom2v from [boot] + [isotp]). The jump runs from NEAR-RESET state by design
 * (docs/bootloader.md): nothing is enabled when the happy path takes it, so nothing is deinit'd.
 * The 0x29 challenge comes from the board's TRNG through diag_board.c's seam — the one RNG driver
 * the application's 0x27 uses too (health-test threshold, seed-error recovery). */
#include <stdint.h>
#include "bootcell.h"
#include "boot_gen.h"

int diag_sa_init(void);
int diag_sa_seed(uint8_t *out, int n);

uint32_t boot_take_request(uint32_t *handoff) {
	uint32_t why = bootcell_take_request();
	*handoff = why == BOOTCELL_REQ_HANDOFF;
	return why != 0;
}

void boot_set_info(uint32_t reason) {
	bootcell_set_info(reason);
}

uint32_t boot_app_base(void) { return APP_BASE; }
uint32_t boot_app_size(void) { return APP_SIZE; }
uint32_t boot_rx_id(void) { return BOOT_RX_ID; }
uint32_t boot_tx_id(void) { return BOOT_TX_ID; }
int boot_can_idx(void) { return BOOT_CAN_IDX; }
int boot_can_fd(void) { return BOOT_CAN_FD; }
uint8_t boot_bs(void) { return BOOT_BS; }
uint8_t boot_stmin(void) { return BOOT_STMIN; }

static const uint8_t g_image_key[32] = BOOT_IMAGE_KEY;
static const uint8_t g_session_key[32] = BOOT_SESSION_KEY;

void boot_keys(uint8_t *image, uint8_t *session) {
	for (int i = 0; i < 32; i++) {
		image[i] = g_image_key[i];
		session[i] = g_session_key[i];
	}
}

int boot_rng(uint8_t *out, int n) {
	return diag_sa_init() && diag_sa_seed(out, n);
}

/* boot_jump_app: VTOR -> the app's vector table, MSP from its word 0, jump to its reset vector. */
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
