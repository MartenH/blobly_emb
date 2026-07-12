/* Minimal Cortex-M startup (M7 and M4F) — vector table + reset.
 * No ST startup file, no CMSIS: init memory and jump to the V main loop. */
#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
/* BOARD_ENTRY defaults to V's `fn main` body (main__main) called directly, NOT V's
 * `int main(int,char**)` wrapper — that wrapper runs _vinit (arg/global setup for a
 * hosted OS) and pulls in the heap runtime, which faults bare-metal. A plain-C image
 * (e.g. the CM4 heartbeat) overrides with -DBOARD_ENTRY=<fn>. */
#ifndef BOARD_ENTRY
#define BOARD_ENTRY main__main
#endif
extern void BOARD_ENTRY(void);

void Default_Handler(void) {
	for (;;) {
	}
}

void Reset_Handler(void) {
	/* -mfloat-abi=hard: enable the FPU (CPACR CP10/CP11 full) — same on M7 and M4F. */
	*(volatile uint32_t *)0xE000ED88u |= (0xFu << 20);
	__asm__ volatile("dsb");
	__asm__ volatile("isb");

	/* .data: copy initializers from flash (LMA) to RAM (VMA). */
	uint32_t *src = &_sidata, *dst = &_sdata;
	while (dst < &_edata) {
		*dst++ = *src++;
	}
	/* .bss: zero. */
	for (dst = &_sbss; dst < &_ebss;) {
		*dst++ = 0;
	}

	BOARD_ENTRY();
	for (;;) {
	}
}

/* Vector table: initial SP + the 15 system exceptions. The FDCAN driver is
 * polled (blob_can_recv drains the Rx FIFO), so no peripheral IRQs are used —
 * all default to Default_Handler. */
__attribute__((section(".isr_vector"), used)) void (*const g_pfnVectors[])(void) = {
    (void (*)(void)) & _estack, /* 0x00 initial SP            */
    Reset_Handler,              /* 0x04 reset                 */
    Default_Handler,            /* NMI                        */
    Default_Handler,            /* HardFault                  */
    Default_Handler,            /* MemManage                  */
    Default_Handler,            /* BusFault                   */
    Default_Handler,            /* UsageFault                 */
    0, 0, 0, 0,                 /* reserved                   */
    Default_Handler,            /* SVCall                     */
    Default_Handler,            /* DebugMonitor               */
    0,                          /* reserved                   */
    Default_Handler,            /* PendSV                     */
    Default_Handler,            /* SysTick                    */
};
