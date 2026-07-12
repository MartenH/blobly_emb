/* CM4 heartbeat — the first code on the H755's second core (multicore rung 3).
 *
 * Counts into the shared-SRAM4 heartbeat cell as fast as the core runs; the CM7's shell
 * `cm4` command reads the counter twice and reports liveness + rate. The rate doubles as
 * a clock probe: it steps visibly when the CM7's bring-up moves HCLK from the boot 64 MHz
 * to 200 MHz — the two cores' first observable interaction.
 *
 * Deliberately touches NOTHING shared-mutable but its own cell, and no RCC/PWR/peripherals
 * (the CM7 owns those). No handshake yet: a pure counter is clock-agnostic, so it simply
 * rides through the CM7's clock transition. Rung 4 replaces this with the IOC triple
 * buffer in the same SRAM4 window.
 */
#include <stdint.h>

/* The heartbeat cell at the bottom of SRAM4 (D3, 0x38000000): uncached on both cores by
 * policy. Owned by convention, not by a linker: neither core's image claims SRAM4. */
#define HB_MAGIC 0x434D3452u /* "CM4R" */
typedef struct {
	volatile uint32_t magic;
	volatile uint32_t counter;
} heartbeat_t;
#define HB ((heartbeat_t *)0x38000000u)

void cm4_main(void) {
	HB->counter = 0u;
	HB->magic = HB_MAGIC;
	for (;;) {
		HB->counter = HB->counter + 1u;
	}
}
