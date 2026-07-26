/* h755_m4_app board/platform glue for the Cortex-M4 — the second core owns NO clocks,
 * NO pins, NO peripherals (the CM7 brings those up); it gets a timebase, the shared-SRAM
 * IOC pool, and the boot handshake. */
#include <stdint.h>
#include <stddef.h>
#include <stm32h7xx.h> /* HSEM registers for the cross-core bulk doorbell (CORE_CM4 build) */
#include "duo.h"
#include "xioc.h"
#include "bulk.h" /* the portable SPSC pool (boards/common) — cross-core bulk lives in the window */
#include "duo_gen.h" /* the GENERATED slot contract (../h755_threadx/gen — one generator run
                      * owns the cross-core map; this satellite image consumes it) */

#define BULK_DOORBELL_SEM 0u /* HSEM semaphore the CM4 rings to wake the CM7 (matches comm_glue.c) */

/* --- boot handshake -------------------------------------------------------------------
 * Park until the CM7 signals clocks-ready (duo.h): the kernel's SysTick is configured
 * against SYSTEM_CLOCK = the FINAL 200 MHz HCLK, so starting before the PLL switch would
 * make the tick 3.125x off. A plain volatile poll: SRAM4 is uncached on both cores. */
void duo_wait_clocks(void) {
	volatile uint32_t *clk = (volatile uint32_t *)DUO_CLK_ADDR;
	while (*clk != DUO_CLK_MAGIC) {
	}
}

/* --- timebase (same contract as board_now_us on the CM7) ------------------------------ */
static volatile uint32_t g_cpu_mhz = 200; /* only ever started after clocks-ready */

void board_timebase_init(void) {
	*(volatile uint32_t *)0xE000EDFCu |= (1u << 24); /* DEMCR.TRCENA */
	*(volatile uint32_t *)0xE0001004u = 0u;          /* DWT.CYCCNT = 0 */
	*(volatile uint32_t *)0xE0001000u |= 1u;         /* DWT.CTRL.CYCCNTENA */
}

uint64_t board_now_us(void) {
	static uint32_t last = 0u;
	static uint64_t acc_cycles = 0u;
	uint32_t prim;
	__asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");
	uint32_t now = *(volatile uint32_t *)0xE0001004u;
	acc_cycles += (uint32_t)(now - last);
	last = now;
	uint64_t r = acc_cycles / g_cpu_mhz;
	__asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");
	return r;
}

/* --- cross-core signal pool ------------------------------------------------------------
 * The pool lives at a fixed SRAM4 address (duo.h), NOT in either image's bss. The channel
 * is xioc (boards/common/xioc.h) — plain-store seq-stamped slots: ioc.h's exchange-based
 * handoff is only sound within one core (its LDREX/STREX doesn't arbitrate across cores
 * on this fabric; 162/200k torn reads measured before this redesign). M4 writes, M7 reads.
 * The generated wrappers publish via duo_pub with slots from gen/duo_gen.h. */
#define DUO_POOL ((xioc_t *)DUO_IOC_ADDR)

void duo_ioc_init(void) {
	for (int i = 0; i < DUO_IOC_N; i++) {
		xioc_init(&DUO_POOL[i]);
	}
}

void duo_pub(int i, uint32_t a, uint32_t b) {
	if (i >= 0 && i < DUO_IOC_N) {
		xioc_write(&DUO_POOL[i], a, b);
	}
}

/* --- wide channels (xioc_n) ------------------------------------------------------------
 * Signals past the {a,b} pair (3+ fields, sub-u32 types, or `valid`) ride size-
 * proportional xioc_n channels in the DUO_XW window; per-signal offsets are generated
 * (gen/duo_gen.h DUO_XW_<SIG>_OFF) and the generated boot inits each channel this image
 * writes. Same plain-store discipline as the pair pool. */
static uint32_t g_boot_seed; /* set by duo_layout_retract, boot's first act */

void duo_xw_init(uint32_t off, uint32_t words) {
	/* seq space seeded per BOOT from the retained epoch (set in duo_layout_retract,
	 * which boot runs first): a reader preempted across our restart can never meet a
	 * colliding sequence number from the new boot (codex #211 r13/r14) */
	xioc_n_init((xioc_n_t *)(DUO_XW_ADDR + off), words, g_boot_seed);
}

void duo_pub_n(uint32_t off, const uint32_t *src) {
	xioc_n_write((xioc_n_t *)(DUO_XW_ADDR + off), src);
}

/* duo_layout_retract — the satellite's FIRST act at boot, before any channel init:
 * on a satellite-only restart beside a live owner, the retained (same-build) id would
 * otherwise keep polling open while init clears slots and restarts wseq under the
 * reader — an ABA window (codex #211 r12). Retract, init, then publish. The owner's
 * per-signal read state may skip exactly one post-restart publish (rd_seq == 1
 * collision); latest-value semantics self-heal at the producer's next cadence. */
void duo_layout_retract(void) {
	/* our HALF of the two-cell handshake: zero the ACK (our cell, one writer — the
	 * owner's REQ cell is never ours to touch, codex #211 r15) so polling stops
	 * before any channel re-init. */
	*(volatile uint32_t *)DUO_LAYOUT_ACK_ADDR = 0u;
	/* restart-UNIQUE epoch: SRAM4 retains the counter across resets, so ++ gives every
	 * boot a distinct value (cold-boot garbage is as good as random) — the DWT clock
	 * restarts at 0 each boot and could repeat (codex #211 r14). Knuth-mixed so
	 * consecutive epochs land far apart in the sequence space; |1 avoids the 0 sentinel. */
	uint32_t e = *(volatile uint32_t *)DUO_EPOCH_ADDR + 1u;
	*(volatile uint32_t *)DUO_EPOCH_ADDR = e;
	g_boot_seed = (e * 2654435761u) | 1u;
	__asm__ volatile("dmb" ::: "memory");
}

/* duo_layout_publish — the satellite's half of the layout handshake: after every
 * channel this image writes is initialized, publish the generated layout id; the owner
 * refuses all remote signals until it matches (stale-image protection, codex #211 r5). */
void duo_layout_publish(void) {
	__asm__ volatile("dmb" ::: "memory"); /* channel inits land before the ack */
	/* ack = the owner's CURRENT req nonce bound to OUR build's layout id: a new owner
	 * boot (new req) is re-acked on the next tick; a stale-build satellite acks a
	 * value the owner never accepts. One reader of req, one writer of ack. */
	uint32_t req = *(volatile uint32_t *)DUO_LAYOUT_REQ_ADDR;
	uint32_t ack = req ^ DUO_LAYOUT_ID;
	if (ack == 0u) ack = 0x4C594F31u; /* 'LYO1' — never the retraction sentinel (r16) */
	*(volatile uint32_t *)DUO_LAYOUT_ACK_ADDR = ack;
	__asm__ volatile("dmb" ::: "memory");
}

/* --- dtrace: the two-core trace handoff (duo.h) -----------------------------------------
 * The recorder itself is trace_hooks.c (exec-change + FB hooks into this core's OWN ring,
 * DWT-timestamped). The bus owner never touches our ring: it posts a request in the SRAM4
 * cell; our app loop services it here — arm clears the ring, snapshot freezes + copies up
 * to 64 wire-form records into the shared buffer and acks with the count. */
void trace_arm(void);
void trace_freeze(void);
unsigned trace_snapshot(unsigned char out[][8], unsigned max);
unsigned long trace_now_us(void);

void duo_trace_service(void) {
	volatile uint32_t *c = (volatile uint32_t *)DUO_TRC_ADDR;
	uint32_t req = c[0];
	if (req == c[2]) {
		return; /* nothing new (c[2] = ack_seq) */
	}
	uint32_t op = c[1];
	if (op == DUO_TRC_OP_ARM) {
		trace_arm();
		c[3] = 0u;
	} else if (op == DUO_TRC_OP_SNAP) {
		trace_freeze();
		c[3] = trace_snapshot((unsigned char (*)[8])DUO_TRC_BUF_ADDR, DUO_TRC_MAX_REC);
	}
	/* Stamp OUR trace clock as late as possible before the ack: this is the owner's midpoint
	 * sample, and every µs between this store and the ack it observes widens the error bound
	 * it computes (REQ-TRACE-011). Same clock the records above are stamped from, so the
	 * offset it yields is the one those records actually need. */
	c[DUO_TRC_SVC_IDX] = (uint32_t)trace_now_us();
	__asm__ volatile("dmb" ::: "memory");
	c[2] = req; /* ack — releases svc_us and the snapshot together */
}

/* The shared vector table (boards/common/vectors.S) names the FDCAN1 and ETH ISRs
 * unconditionally; the M7 board.c weak defaults don't apply here (this image links
 * without board.c). This core never enables either IRQ in its NVIC — the CM7 owns
 * the bus and the MAC — so parked stubs satisfy the link and would trap loudly if
 * they ever fired. */
void FDCAN1_IT0_IRQHandler(void) {
	for (;;) {
	}
}

void ETH_IRQHandler(void) {
	for (;;) {
	}
}

/* --- cross-core bulk PRODUCER (docs/bulk-transport.md, ecu.toml [[bulk]] "xfer") ------------
 * The bulk pool lives in the H755 shared window; the generated code externs duo_bulk_base()
 * and the platform (here) owns the pool — no FB ever touches it. This M4 side is the PRODUCER:
 * once per service pass it loans a buffer, fills 256 B with a seq-derived pattern (seq in the
 * first 4 bytes, DUO_STRESS_K*seq+i in the rest — tear/corruption detectable by the consumer),
 * and publishes. The CM7 comm thread consumes and verifies. Counters are SWD-observable. */
size_t duo_bulk_base(void) { return (size_t)DUO_BULK_ADDR; }

uint32_t g_bulk_tx_seq  = 0; /* blocks published */
uint32_t g_bulk_tx_full = 0; /* loan failures: consumer slower than producer (REQ-BULK-002) */
static int s_xfer_inited = 0;

void duo_bulk_produce(void) {
	/* SINGLE-POOL DEMO: "xfer" is the only cross-core pool, so it sits at offset 0 =
	 * DUO_BULK_ADDR and the geometry (4 x 256) matches ecu.toml [[bulk]] and the generated
	 * bulk_xfer_* wrappers. A SECOND pool (or changed nbuf/bufsz) would move the offset /
	 * geometry — a real multi-pool consumer must read them from the generated contract, not
	 * hardcode. Kept literal here because the whole point is a minimal transport proof. */
	bulk_t *p = (bulk_t *)DUO_BULK_ADDR;
	/* the producer owns bring-up: init once, the consumer polls bulk_valid() before first use */
	if (!s_xfer_inited) {
		bulk_init(p, 4u, 256u);
		s_xfer_inited = 1;
	}
	/* Take the sequence number for THIS attempt up front, so a dropped loan leaves a hole in
	 * the published sequence — that hole is exactly what the consumer's g_bulk_rx_gap counts.
	 * (Advancing only on success would make the published seq contiguous, so rx_gap could never
	 * report a drop — the whole point of the backpressure metric.) */
	uint32_t seq = g_bulk_tx_seq++;
	int idx = bulk_loan(p);
	if (idx < 0) {
		g_bulk_tx_full++; /* seq is skipped (never published) -> the consumer sees a gap */
		return;
	}
	uint8_t *b = bulk_buf(p, (uint32_t)idx);
	b[0] = (uint8_t)seq;
	b[1] = (uint8_t)(seq >> 8);
	b[2] = (uint8_t)(seq >> 16);
	b[3] = (uint8_t)(seq >> 24);
	for (uint32_t i = 4; i < 256u; i++) {
		b[i] = (uint8_t)(seq * DUO_STRESS_K + i);
	}
	bulk_publish(p, (uint32_t)idx, 256u);

	/* Ring the cross-core doorbell: a 1-step fast-take then release of HSEM semaphore 0 raises
	 * IRQ125 on the CM7 (which enabled C1IER for this semaphore), waking its comm thread to drain
	 * us — no CM7 polling. Uncontended (only this core touches sem 0's lock, and we release it
	 * immediately), so the take always succeeds; the release value carries our COREID from the
	 * lock read-back, so we don't hardcode which core we are. */
	uint32_t rl = HSEM->RLR[BULK_DOORBELL_SEM];          /* fast-take: lock for this core */
	HSEM->R[BULK_DOORBELL_SEM] = rl & HSEM_R_COREID_Msk; /* release -> HSEM1 interrupt on the CM7 */
}
