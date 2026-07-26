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
/* The layout handshake is TWO SPSC cells — one writer each, per the transport's own
 * hard invariant (a single shared cell had both cores writing it — codex #211 r15):
 *   REQ (owner-owned):  a retained per-owner-boot nonce; a new owner boot bumps it,
 *                       instantly invalidating every previous acknowledgement.
 *   ACK (sat-owned):    req ^ DUO_LAYOUT_ID (gen/duo_gen.h), recomputed every service
 *                       tick and ZEROED first thing at satellite boot, so polls stop
 *                       while channels re-init. Owner polls nothing until ACK matches. */
#define DUO_LAYOUT_REQ_ADDR 0x38000010u
#define DUO_LAYOUT_ACK_ADDR 0x38000014u
#define DUO_EPOCH_ADDR      0x38000018u /* retained satellite boot-epoch: bumped once per
                                         * boot (SRAM4 survives resets) -> restart-unique
                                         * wide-channel sequence seeds (DWT restarts at 0) */
#define DUO_IOC_ADDR   0x38000020u
#define DUO_IOC_N      4

#define DUO_TRC_ADDR     0x38000200u
#define DUO_TRC_SVC_IDX  4u        /* cell word 4 = the satellite's service-time stamp (µs) */
#define DUO_TRC_BUF_ADDR 0x38000220u /* cell is 8 words; records start after it */
#define DUO_TRC_MAX_REC  256u /* = the satellite recorder's RING_CAP */
#define DUO_TRC_OP_ARM   1u
#define DUO_TRC_OP_SNAP  2u

/* Wide xioc_n channels (remote signals past the {a,b} pair cell — REQ-INV-006): the
 * generator lays out per-signal offsets inside this window (gen/duo_gen.h
 * DUO_XW_<SIG>_OFF, 32 B-aligned) and static-checks the budget against DUO_XW_MAX.
 * 0x38001000 clears the dtrace record buffer (0x38000220 + 256*8 = 0x38000A20). */
#define DUO_XW_ADDR 0x38001000u
#define DUO_XW_MAX  0x1000u

/* Cross-core BULK pools (docs/bulk-transport.md, ROADMAP "bulk ecu.toml surface"): a
 * [[bulk]] whose producer and consumer sit on DIFFERENT cores places its bulk_t pool in
 * this window instead of a per-image global, so both images address the SAME bytes. The
 * generator lays out per-pool offsets (32 B-aligned) and static-checks the total against
 * DUO_BULK_MAX. Starts after the wide-xioc window and runs to the top of SRAM4 (0x38010000). */
#define DUO_BULK_ADDR 0x38002000u
#define DUO_BULK_MAX  0xE000u

/* Platform seam for the cross-core bulk base — generated code externs `duo_bulk_base()` and
 * adds the per-pool offset, exactly as it externs duo_pub/duo_ioc_init for xioc. It NEVER
 * includes this board header; the image's glue C provides the body. Defined here as the one
 * source of DUO_BULK_ADDR (each glue TU that includes duo.h gets its own copy — the address
 * is a constant, so the copies are identical). */
static inline size_t duo_bulk_base(void) { return (size_t)DUO_BULK_ADDR; }

/* Slot assignments are GENERATED — gen/duo_gen.h (loom2v [duo]) is the one source; both
 * images compile against it. Only the pool geometry lives here. */

#endif
