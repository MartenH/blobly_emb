/* The sampling CPU profiler (cpuprof.h).
 *
 * What the core was doing is read from the exception TIM7 interrupted:
 *   thread mode            a ThreadX thread: _tx_thread_current_ptr says which
 *   handler mode, PendSV,  ThreadX's scheduler; with no current thread it is the idle wait
 *     no current thread    (__tx_ts_wait spins inside PendSV on this port)
 *   any other handler      an interrupt (SysTick, FDCAN, ETH, or PendSV switching threads)
 * EXC_RETURN bit 3 clear means TIM7 interrupted handler mode, whose frame is on MSP; the exception
 * number of what it interrupted is in the xPSR of that frame (word 7, basic or FPU-extended alike).
 */
#include <stm32h735xx.h>
#include "cpuprof.h"

extern TX_THREAD *_tx_thread_current_ptr;

static cpuprof_t g_prof; /* written by the sampling ISR alone */

void cpuprof_sample(uint32_t exc_return, const uint32_t *msp) {
	TIM7->SR = 0u;
	cpuprof_t *p = &g_prof;
	p->total++;
	TX_THREAD *cur = _tx_thread_current_ptr;
	if ((exc_return & 8u) == 0u) { /* a handler was interrupted: its frame is on MSP */
		uint32_t ipsr = msp[7] & 0x1FFu;
		if (ipsr == 14u && cur == TX_NULL) p->idle++; /* PendSV with no thread: the idle wait */
		else p->isr++;
		return;
	}
	if (cur == TX_NULL) {
		p->idle++;
		return;
	}
	for (uint32_t i = 0; i < p->n; i++) {
		if (p->thread[i] == cur) {
			p->count[i]++;
			return;
		}
	}
	if (p->n < CPUPROF_THREADS) {
		p->thread[p->n] = cur;
		p->count[p->n] = 1u;
		p->n++; /* the slot is filled before n admits a reader to it */
	} else {
		p->other++;
	}
}

/* the vector: hand the sampler EXC_RETURN and the main stack pointer exactly as they were at
 * entry (a C prologue would move MSP) */
__attribute__((naked)) void TIM7_IRQHandler(void) {
	__asm volatile("mov r0, lr\n"
	               "mrs r1, msp\n"
	               "b cpuprof_sample\n");
}

void cpuprof_start(void) {
	RCC->APB1LENR |= RCC_APB1LENR_TIM7EN;
	(void)RCC->APB1LENR;
	TIM7->CR1 = 0u;
	TIM7->PSC = 0u;
	TIM7->ARR = 27575u - 1u; /* 275 MHz timer clock (APB1 x2) / 27575 = 9973 Hz */
	TIM7->EGR = TIM_EGR_UG;
	TIM7->SR = 0u;
	TIM7->DIER = TIM_DIER_UIE;
	NVIC_SetPriority(TIM7_IRQn, 0u);
	NVIC_EnableIRQ(TIM7_IRQn);
	TIM7->CR1 = TIM_CR1_CEN;
}

void cpuprof_read(cpuprof_t *out) {
	out->n = *(volatile uint32_t *)&g_prof.n;
	for (uint32_t i = 0; i < out->n; i++) {
		out->thread[i] = g_prof.thread[i];
		out->count[i] = *(volatile uint32_t *)&g_prof.count[i];
	}
	out->other = *(volatile uint32_t *)&g_prof.other;
	out->isr = *(volatile uint32_t *)&g_prof.isr;
	out->idle = *(volatile uint32_t *)&g_prof.idle;
	out->total = *(volatile uint32_t *)&g_prof.total;
}
