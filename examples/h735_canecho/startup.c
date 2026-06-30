/* Minimal Cortex-M7 startup for the STM32H735 — vector table + reset.
 * No ST startup file, no CMSIS: init memory and jump to the V main loop. */
#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
/* Call V's `fn main` body directly (main__main), NOT V's `int main(int,char**)`
 * wrapper — that wrapper runs _vinit (arg/global setup for a hosted OS) and pulls
 * in the heap runtime, which faults bare-metal. main.v only calls C shims, so it
 * needs none of that; bypassing it also lets the linker drop the whole runtime. */
extern void main__main(void);

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

	main__main();
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
