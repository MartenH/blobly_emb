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

/* Vector table: initial SP + the 15 system exceptions + EVERY interrupt line the part has,
 * all on Default_Handler. The FDCAN driver is polled (blob_can_recv drains the Rx FIFO), so no
 * peripheral IRQ is armed — but the table still spans the part's full range, so a line that
 * does fire lands here rather than on whatever follows the table. VECTOR_IRQS is the part's
 * highest IRQn + 1, checked against the CMSIS IRQn_Type enum by tools/vectab/vectab_test.v. */
#if defined(STM32H723xx) || defined(STM32H725xx) || defined(STM32H730xx) || defined(STM32H733xx) || defined(STM32H735xx)
#define VECTOR_IRQS 163 /* RM0468: IRQ0..IRQ162 (TIM24) */
#elif defined(STM32H745xx) || defined(STM32H755xx)
#define VECTOR_IRQS 150 /* RM0399: IRQ0..IRQ149 (WAKEUP_PIN) */
#else
#error "startup.c: no VECTOR_IRQS for this part — add it from the part's CMSIS IRQn_Type enum"
#endif

__attribute__((section(".isr_vector"), used)) void (*const g_pfnVectors[16 + VECTOR_IRQS])(void) = {
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
    [16 ... 16 + VECTOR_IRQS - 1] = Default_Handler,
};
