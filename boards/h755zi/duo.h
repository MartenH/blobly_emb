/* duo.h — the H755 dual-core shared-memory map (D3 SRAM4, 0x38000000, 64 KB).
 *
 * SRAM4 is reachable from both cores and UNCACHED on both by policy (D-caches off), so
 * plain volatile accesses are coherent. Nothing here is claimed by either core's linker:
 * the layout is this header, included by both images — one convention, two consumers.
 *
 *   +0x00  heartbeat: magic 'CM4R' + free-running counter (the CM4 writes, rung 3)
 *   +0x08  clocks-ready: magic 'CLKR' the CM7 writes AFTER board_clock_init — the CM4
 *          parks until it appears, so its SysTick is configured against the final
 *          200 MHz HCLK, never the 64 MHz boot clock
 *   +0x20  cross-core IOC pool: ioc_t[DUO_IOC_N] (32 B each, line-aligned)
 *          slot 0 = the M4 FB's signal {n, acc}     (semantic, 100 Hz)
 *          slot 1 = the stress channel {n, n*K}     (max-rate, tear detection)
 */
#ifndef BLOBLY_H755_DUO_H
#define BLOBLY_H755_DUO_H

#include <stdint.h>

#define DUO_HB_MAGIC   0x434D3452u /* "CM4R" */
#define DUO_CLK_MAGIC  0x434C4B52u /* "CLKR" */
#define DUO_STRESS_K   2654435761u /* Knuth hash: stress payload b = n * K (tear check) */

#define DUO_HB_ADDR    0x38000000u
#define DUO_CLK_ADDR   0x38000008u
#define DUO_IOC_ADDR   0x38000020u
#define DUO_IOC_N      4

#define DUO_SLOT_M4SIG  0
#define DUO_SLOT_STRESS 1

#endif
