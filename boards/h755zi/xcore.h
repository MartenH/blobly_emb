/* xcore.h — the H755 dual-core shared-memory map (D3 SRAM4, 0x38000000, 64 KB).
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
 *          then the wire-form records at +0x220 (XCORE_TRC_MAX_REC * 8 B). The bus owner
 *          requests (op 1 = arm, 2 = freeze+snapshot); the satellite's app loop services it
 *          and acks; the owner imports the snapshot as that core's dump block
 *          (TraceModule.load_remote). Single writer per field.
 *          svc_us is the satellite's trace_now_us() AT SERVICE TIME — the middle stamp of
 *          the owner's request/ack round trip, which is what makes the two cores' records
 *          comparable at all (REQ-TRACE-011). Each core's trace clock counts from its own
 *          first tick, so without this the blocks share no timeline; the owner brackets the
 *          exchange with its own t1/t3 and derives offset + error bound from the three.
 *   +0x20  cross-core IOC pool: xioc_t[XCORE_IOC_N] (96 B each, line-aligned — see
 *          boards/common/xioc.h: plain-store seq-stamped slots; ioc.h's exchange-based
 *          triple buffer is NOT cross-core safe on this fabric, measured 2026-07-12)
 *          slot 0 = the M4 FB's signal {n, acc}     (semantic, 100 Hz)
 *          slot 1 = the stress channel {n, n*K}     (max-rate, tear detection)
 */
#ifndef BLOBLY_H755_XCORE_H
#define BLOBLY_H755_XCORE_H

#include <stdint.h>

#define XCORE_HB_MAGIC   0x434D3452u /* "CM4R" */
#define XCORE_CLK_MAGIC  0x434C4B52u /* "CLKR" */
#define XCORE_STRESS_K   2654435761u /* Knuth hash: stress payload b = n * K (tear check) */

#define XCORE_HB_ADDR    0x38000000u
#define XCORE_CLK_ADDR   0x38000008u
/* The layout handshake is TWO SPSC cells — one writer each, per the transport's own
 * hard invariant (a single shared cell had both cores writing it — codex #211 r15):
 *   REQ (owner-owned):  a retained per-owner-boot nonce; a new owner boot bumps it,
 *                       instantly invalidating every previous acknowledgement.
 *   ACK (sat-owned):    req ^ XCORE_LAYOUT_ID (gen/xcore_gen.h), recomputed every service
 *                       tick and ZEROED first thing at satellite boot, so polls stop
 *                       while channels re-init. Owner polls nothing until ACK matches. */
#define XCORE_LAYOUT_REQ_ADDR 0x38000010u
#define XCORE_LAYOUT_ACK_ADDR 0x38000014u
#define XCORE_EPOCH_ADDR      0x38000018u /* retained satellite boot-epoch: bumped once per
                                         * boot (SRAM4 survives resets) -> restart-unique
                                         * wide-channel sequence seeds (DWT restarts at 0) */
#define XCORE_IOC_ADDR   0x38000020u
#define XCORE_IOC_N      4

#define XCORE_TRC_ADDR     0x38000200u
#define XCORE_TRC_SVC_IDX  4u        /* cell word 4 = the satellite's service-time stamp (µs) */
#define XCORE_TRC_BUF_ADDR 0x38000220u /* cell is 8 words; records start after it */
#define XCORE_TRC_MAX_REC  256u /* = the satellite recorder's RING_CAP */
#define XCORE_TRC_OP_ARM   1u
#define XCORE_TRC_OP_SNAP  2u

/* Wide xioc_n channels (remote signals past the {a,b} pair cell — REQ-INV-006): the
 * generator lays out per-signal offsets inside this window (gen/xcore_gen.h
 * XCORE_XW_<SIG>_OFF, 32 B-aligned) and static-checks the budget against XCORE_XW_MAX.
 * 0x38001000 clears the dtrace record buffer (0x38000220 + 256*8 = 0x38000A20). */
#define XCORE_XW_ADDR 0x38001000u
#define XCORE_XW_MAX  0x1000u

/* Cross-core BULK pools (docs/bulk-transport.md, ROADMAP "bulk ecu.toml surface"): a
 * [[bulk]] whose producer and consumer sit on DIFFERENT cores places its bulk_t pool in
 * this window instead of a per-image global, so both images address the SAME bytes. The
 * generator lays out per-pool offsets (32 B-aligned) and static-checks the total against
 * XCORE_BULK_MAX. Starts after the wide-xioc window and runs to the top of SRAM4 (0x38010000). */
#define XCORE_BULK_ADDR 0x38002000u
#define XCORE_BULK_MAX  0xE000u

/* HSEM semaphore for the cross-core bulk doorbell: the CM4 releases it after each publish to
 * raise IRQ125 (HSEM1) on the CM7, whose ISR wakes the comm thread to drain the pool. ONE source
 * for both sides (m4_glue.c rings it, comm_glue.c enables/clears/handles it) so they can't drift. */
#define XCORE_BULK_DOORBELL_SEM 0u

/* Bench-only control cell (NOT part of the transport): the CM7 sets it to 1 to ask the CM4
 * producer to BURST — fill+publish flat-out, word-wise, no doorbell — so bulkperf can measure the
 * pool's raw cross-core throughput unpaced by the M4 service loop; the CM7 clears it after its
 * timing window. Lives in the unused SRAM4 gap (dtrace records end 0x38000A20, XCORE_XW at
 * 0x38001000), so it collides with nothing in the map above. */
#define XCORE_BULK_BURST_ADDR 0x38000C00u

/* Cross-core CpuLoad: each satellite image publishes its own core's per-mille processor load
 * (loom sched.load_permille(), 0..1000) into its slot here; the owner's comm thread reads the
 * satellite slots into the CpuLoad frame so it reports EVERY core, not just its own. u16[8],
 * indexed by core (owner writes nothing — it has its own sched). In the SRAM4 gap. */
#define XCORE_LOAD_ADDR 0x38000C10u

/* Platform seam for the cross-core bulk base: generated code externs `xcore_bulk_base()` and adds
 * the per-pool offset, and NEVER includes this board header — so an image that declares a
 * cross-core [[bulk]] pool must DEFINE the seam in its glue C, exactly like xcore_pub/xcore_ioc_init:
 *
 *     #include "xcore.h"
 *     size_t xcore_bulk_base(void) { return (size_t)XCORE_BULK_ADDR; }   // owner AND satellite glue
 *
 * (A `static inline` here would NOT satisfy the generated TU's external reference — internal
 * linkage — so the seam is deliberately left to the glue, not defined in this header.) */

/* Slot assignments are GENERATED — gen/xcore_gen.h (loom2v [duo]) is the one source; both
 * images compile against it. Only the pool geometry lives here. */

#endif
