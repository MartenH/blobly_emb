/* Minimal Cortex-M7 startup for the STM32H735 — vector table + reset.
 * No ST startup file, no CMSIS: ~50 lines that init memory and call V's main(). */
#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
extern int main(int argc, char **argv); /* V's generated entry */

void Default_Handler(void) {
	for (;;) {
	}
}

void Reset_Handler(void) {
	/* Cortex-M7 with -mfloat-abi=hard: enable the FPU (CPACR CP10/CP11 full). */
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

	main(0, 0);
	for (;;) {
	}
}

/* Vector table: initial SP + the 15 system exceptions. Peripheral IRQs default
 * to Default_Handler; the blinky uses none. */
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
