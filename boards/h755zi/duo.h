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
 *   +0x200 dtrace handoff (two-core trace): {req_seq, op, ack_seq, count, svc_us, rsvd[3]}
 *          then the wire-form records at +0x220 (DUO_TRC_MAX_REC * 8 B). The bus owner
 *          requests (op 1 = arm, 2 = freeze+snapshot); the satellite's app loop services it
 *          and acks; the owner imports the snapshot as that core's dump block
 *          (TraceModule.load_remote). Single writer per field.
 *          svc_us is the satellite's trace_now_us() AT SERVICE TIME — the middle stamp of
 *          the owner's request/ack round trip, which is what makes the two cores' records
 *          comparable at all (REQ-TRACE-011). Each core's trace clock counts from its own
 *          first tick, so without this the blocks share no timeline; the owner brackets the
 *          exchange with its own t1/t3 and derives offset + error bound from the three.
 *   +0x20  cross-core IOC pool: xioc_t[DUO_IOC_N] (96 B each, line-aligned — see
 *          boards/common/xioc.h: plain-store seq-stamped slots; ioc.h's exchange-based
 *          triple buffer is NOT cross-core safe on this fabric, measured 2026-07-12)
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

#define DUO_TRC_ADDR     0x38000200u
#define DUO_TRC_SVC_IDX  4u        /* cell word 4 = the satellite's service-time stamp (µs) */
#define DUO_TRC_BUF_ADDR 0x38000220u /* cell is 8 words; records start after it */
#define DUO_TRC_MAX_REC  256u /* = the satellite recorder's RING_CAP */
#define DUO_TRC_OP_ARM   1u
#define DUO_TRC_OP_SNAP  2u

/* Slot assignments are GENERATED — gen/duo_gen.h (loom2v [duo]) is the one source; both
 * images compile against it. Only the pool geometry lives here. */

#endif
