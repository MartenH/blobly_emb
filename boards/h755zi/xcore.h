/* xcore.h — the H755 dual-core shared-memory map (D3 SRAM4, 0x38000000, 64 KB).
 *
 * SRAM4 is reachable from both cores and UNCACHED on both by policy (D-caches off), so
 * plain volatile accesses are coherent. Nothing here is claimed by either core's linker:
 * the layout is this header, included by both images — one convention, two consumers.
 *
 *   +0x00  heartbeat: magic 'CM4R' + free-running counter (the CM4 writes, rung 3)
 *   +0x08  clocks-ready: magic 'CLKR' the CM7 writes AFTER board_clock_init — the CM4
 *          parks until it appears (and consumes it: xcore_clk_take), so its SysTick is configured against the final
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
 *          triple buffer is NOT cross-core safe on this fabric, measured 2026-07-12).
 *          Satellite-written; slot assignments are generated (gen/xcore_gen.h XCORE_SLOT_*)
 *   +0x1000 wide xioc_n channels, satellite-written (XCORE_XW_*)
 *   +0x2000 cross-core bulk pools (XCORE_BULK_*)
 *   +0xF000 owner-written window (XCORE_OW_*): the owner's layout ack + boot nonce, then the
 *          owner -> satellite xioc_n channels (generated offsets, gen/xcore_gen.h XCORE_OW_*)
 */
#ifndef BLOBLY_H755_XCORE_H
#define BLOBLY_H755_XCORE_H

#include <stdint.h>
#include <stddef.h> /* offsetof, for the checks against the vendor header */

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
/* The clock-release cell is a CONSUMED handshake (the ONE statement of it — the owner, the
 * satellite and the boot manager all go through these): SRAM4 survives a system reset, so a magic
 * left behind would release the next boot's satellite before anybody set the clocks — and a boot
 * manager that STAYS for programming reconfigures the clocks under a CM4 that already started its
 * kernel. So the satellite consumes the magic as it takes it, and the CM7 retracts it before it
 * touches the clocks on any path that does not release it (boot/target/main.v). */
static inline void xcore_clk_release(void) {
	*(volatile uint32_t *)XCORE_CLK_ADDR = XCORE_CLK_MAGIC;
	__asm__ volatile("dsb");
}

static inline void xcore_clk_retract(void) {
	*(volatile uint32_t *)XCORE_CLK_ADDR = 0u;
	__asm__ volatile("dsb");
}

/* satellite: the CM4's ART accelerator, the cache in front of its flash fetches. It is off at
 * reset, and off every fetch from bank 2 waits on the flash: the same work measured 19.6 % of the
 * CM4 with it off and 7.5 % on (system_full's domain_m4). Its clock goes on through the CM4's own
 * RCC view (RCC_C2_AHB1ENR.ARTEN), so no read-modify-write races the CM7's, and it caches the 1 MB
 * page this code runs from (PCACHEADDR = address bits 31:20). The CM7's NvM journal shares bank 2,
 * but the CM4 never reads it, so a journal write leaves no stale line the CM4 could fetch. The
 * numbers are spelled out so the host tests can include this header; where the vendor header is
 * in, they are checked against it. */
#define XCORE_RCC_C2_AHB1ENR 0x58024598u
#define XCORE_RCC_ARTEN      (1u << 14)
#define XCORE_ART_CTR        0x40024400u
#define XCORE_ART_EN         1u
#define XCORE_ART_PAGE_MSK   0x000FFF00u
#ifdef RCC_C2_BASE
_Static_assert(XCORE_RCC_C2_AHB1ENR == RCC_C2_BASE + offsetof(RCC_Core_TypeDef, AHB1ENR), "RCC_C2 AHB1ENR");
_Static_assert(XCORE_RCC_ARTEN == RCC_AHB1ENR_ARTEN, "ARTEN");
_Static_assert(XCORE_ART_CTR == ART_BASE + offsetof(ART_TypeDef, CTR), "ART CTR");
_Static_assert(XCORE_ART_EN == ART_CTR_EN && XCORE_ART_PAGE_MSK == ART_CTR_PCACHEADDR_Msk, "ART CTR bits");
#endif

static inline void xcore_sat_art_on(void) {
	volatile uint32_t *en = (volatile uint32_t *)(uintptr_t)XCORE_RCC_C2_AHB1ENR;
	volatile uint32_t *ctr = (volatile uint32_t *)(uintptr_t)XCORE_ART_CTR;
	*en |= XCORE_RCC_ARTEN;
	(void)*en; /* read back: the clock is on before the ART is written */
	uint32_t page = (uint32_t)(uintptr_t)&xcore_sat_art_on;
	*ctr = (page >> 12) & XCORE_ART_PAGE_MSK; /* the page first, with the cache off */
	*ctr |= XCORE_ART_EN;
	__asm__ volatile("dsb; isb");
}

/* satellite: park until released, then consume the release — the satellite's start, so its ART
 * cache goes on here, in every satellite image (threadx_makefiles_test.v pins that each calls this) */
static inline void xcore_clk_take(void) {
	volatile uint32_t *clk = (volatile uint32_t *)XCORE_CLK_ADDR;
	while (*clk != XCORE_CLK_MAGIC) {
	}
	*clk = 0u;
	__asm__ volatile("dsb");
	xcore_sat_art_on();
}

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
 * XCORE_BULK_MAX. Starts after the wide-xioc window and runs to the owner-written window. */
#define XCORE_BULK_ADDR 0x38002000u
#define XCORE_BULK_MAX  0xD000u

/* Owner-written window (owner -> satellite signals): the top 4 KB of SRAM4, above the bulk pools.
 * The OWNER is the only writer of every cell here; the satellite only reads. The gate:
 *   NONCE  a retained per-owner-boot value, odd, new every boot (xcore_owner_begin)
 *   ACK    xcore_ow_ack(NONCE ^ XCORE_LAYOUT_ID), written after every channel is initialised
 *          (xcore_owner_commit); 0 = retracted (owner re-initialising, or a boot manager parked
 *          the satellite). A reader opens the gate only on an exact match, so a different build
 *          or a previous owner boot reads as never-fresh.
 * The channels are xioc_n channels at generated 32 B-aligned offsets from XCORE_OW_CH_ADDR
 * (gen/xcore_gen.h XCORE_OW_<SIG>_OFF), budgeted against XCORE_OW_MAX. The base is overridable so
 * the host test can place the window in an ordinary array. */
#ifndef XCORE_OW_BASE
#define XCORE_OW_BASE 0x3800F000u
#if XCORE_BULK_ADDR + XCORE_BULK_MAX > XCORE_OW_BASE
#error "cross-core bulk window overlaps the owner-written window"
#endif
#if XCORE_OW_BASE + 0x1000u > 0x38010000u
#error "owner-written window runs past the end of SRAM4"
#endif
#endif
#define XCORE_OW_ACK_ADDR   (XCORE_OW_BASE + 0x00u) /* owner: xcore_ow_ack(nonce ^ LAYOUT_ID), 0 = retracted */
#define XCORE_OW_NONCE_ADDR (XCORE_OW_BASE + 0x04u) /* owner: retained boot nonce, odd, new per boot */
#define XCORE_OW_CH_ADDR    (XCORE_OW_BASE + 0x20u) /* xioc_n channels, generator offsets from here */
#define XCORE_OW_MAX        0x0FE0u

/* the ack value for nonce ^ layout id: never 0, which is the retraction */
static inline uint32_t xcore_ow_ack(uint32_t v) {
	return v != 0u ? v : 0x4C594F31u; /* 'LYO1' */
}

/* owner side (xcore_owner.c, board.mk BOARD_XCORE_OWNER): begin, init each channel, commit —
 * all before xcore_clk_release; then publish */
void xcore_owner_begin(void);
void xcore_ow_init(uint32_t off, uint32_t words);
void xcore_owner_commit(void);
void xcore_opub_n(uint32_t off, const uint32_t *src);
/* satellite side (xcore_sat.c, board.mk BOARD_XCORE_SAT): st = {owner nonce, rd_seq, lanes[words]};
 * 1 = the lanes hold a value published in this owner boot, 0 = default (lanes zero) */
int xcore_down_read(uint32_t off, uint32_t words, uint32_t *st);

/* HSEM semaphore for the cross-core bulk doorbell: the CM4 releases it after each publish to
 * raise IRQ125 (HSEM1) on the CM7, whose ISR wakes the comm thread to drain the pool. ONE source
 * for both sides (m4_glue.c rings it, target_ext.c enables/clears/handles it) so they can't drift. */
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
