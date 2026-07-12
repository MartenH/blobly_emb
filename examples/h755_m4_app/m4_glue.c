/* h755_m4_app board/platform glue for the Cortex-M4 — the second core owns NO clocks,
 * NO pins, NO peripherals (the CM7 brings those up); it gets a timebase, the shared-SRAM
 * IOC pool, and the boot handshake. */
#include <stdint.h>
#include "duo.h"
#include "xioc.h"

/* --- boot handshake -------------------------------------------------------------------
 * Park until the CM7 signals clocks-ready (duo.h): the kernel's SysTick is configured
 * against SYSTEM_CLOCK = the FINAL 200 MHz HCLK, so starting before the PLL switch would
 * make the tick 3.125x off. A plain volatile poll: SRAM4 is uncached on both cores. */
void duo_wait_clocks(void) {
	volatile uint32_t *clk = (volatile uint32_t *)DUO_CLK_ADDR;
	while (*clk != DUO_CLK_MAGIC) {
	}
}

/* --- timebase (same contract as board_now_us on the CM7) ------------------------------ */
static volatile uint32_t g_cpu_mhz = 200; /* only ever started after clocks-ready */

void board_timebase_init(void) {
	*(volatile uint32_t *)0xE000EDFCu |= (1u << 24); /* DEMCR.TRCENA */
	*(volatile uint32_t *)0xE0001004u = 0u;          /* DWT.CYCCNT = 0 */
	*(volatile uint32_t *)0xE0001000u |= 1u;         /* DWT.CTRL.CYCCNTENA */
}

uint64_t board_now_us(void) {
	static uint32_t last = 0u;
	static uint64_t acc_cycles = 0u;
	uint32_t prim;
	__asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");
	uint32_t now = *(volatile uint32_t *)0xE0001004u;
	acc_cycles += (uint32_t)(now - last);
	last = now;
	uint64_t r = acc_cycles / g_cpu_mhz;
	__asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");
	return r;
}

/* --- cross-core IOC + heartbeat -------------------------------------------------------
 * The pool lives at a fixed SRAM4 address (duo.h), NOT in either image's bss. The channel
 * is xioc (boards/common/xioc.h) — plain-store seq-stamped slots: ioc.h's exchange-based
 * handoff is only sound within one core (its LDREX/STREX doesn't arbitrate across cores
 * on this fabric; 162/200k torn reads measured before this redesign). M4 writes, M7 reads. */
#define DUO_POOL ((xioc_t *)DUO_IOC_ADDR)

void duo_ioc_init(void) {
	for (int i = 0; i < DUO_IOC_N; i++) {
		xioc_init(&DUO_POOL[i]);
	}
	volatile uint32_t *hb = (volatile uint32_t *)DUO_HB_ADDR;
	hb[1] = 0u;
	hb[0] = DUO_HB_MAGIC;
}

void duo_pub(int i, uint32_t a, uint32_t b) {
	if (i >= 0 && i < DUO_IOC_N) {
		xioc_write(&DUO_POOL[i], a, b);
	}
}

void duo_hb_bump(void) {
	volatile uint32_t *hb = (volatile uint32_t *)DUO_HB_ADDR;
	hb[1] = hb[1] + 1u;
}

/* The shared vector table (boards/common/vectors.S) names the FDCAN1 ISR unconditionally
 * and deliberately provides no weak default (see the warning there). This core never
 * enables that IRQ in its NVIC — the CM7 owns the bus — so a parked stub satisfies the
 * link and would trap loudly if it ever fired. */
void FDCAN1_IT0_IRQHandler(void) {
	for (;;) {
	}
}
