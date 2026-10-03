/* system_full domain (H755 CM7) target extensions: the dual-core handoff (xcore layout, cross-core trace, bulk
 * consumer and its HSEM doorbell), the [nvm] storage map, and the shell's own target commands (the built-in ps/bmc are
 * boards/common/shell_glue.c).
 *
 * The generic glue every generated image links — the IOC pool, the load cells, the FDCAN Rx
 * ISR and the comm-thread wake semaphore — is boards/common/comm_glue.c, listed by
 * gen/loom_build.mk (LOOM_GLUE_SRCS). This file adds only what is this image's own, and
 * defines nothing that one does: its one extra wake source arms in comm_wake_sources_arm and
 * posts through comm_wake.
 */
#include "tx_api.h"
#include <stm32h7xx.h>
#include <stddef.h>
#include "ioc.h"
#include "board.h" /* board_now_us for the cm4 rate window */
#include "xcore.h"  /* the dual-core shared-SRAM map (heartbeat, clocks-ready, IOC pool) */
#include "bulk.h" /* the portable SPSC pool (boards/common) — cross-core bulk consumer side */

/* output helpers for this node's own shell commands (the built-ins are boards/common/shell_glue.c) */
static char *ps_str(char *p, char *end, const char *s) {
    while (*s && p < end) *p++ = *s++;
    return p;
}
static char *ps_u32(char *p, char *end, unsigned v) {
    char d[10]; int n = 0;
    if (!v) { if (p < end) *p++ = '0'; return p; }
    while (v) { d[n++] = (char)('0' + v % 10u); v /= 10u; }
    while (n && p < end) *p++ = d[--n];
    return p;
}
/* shell_bulkperf — the `bulkperf` command: measure the cross-core [[bulk]] "model" pool's RAW
 * throughput, unpaced by the M4 service loop. Raises the CM4 burst flag (m4_glue.c produces
 * flat-out, word-wise, no doorbell), spin-drains take+release for a fixed window counting blocks,
 * then lowers the flag. blocks*256 B / window = the pool's cross-core bandwidth. No payload verify
 * (integrity is the paced path's job); this isolates the transport+copy rate, bounded by the CM4's
 * uncached D2->D3 SRAM4 writes. The comm thread is busy for the window (~0.2 s) — operator probe. */
void xcore_bulk_resync(void); /* re-baseline the paced-demo integrity state (defined by xcore_bulk_consume) */
int shell_bulkperf(unsigned char *out, int cap) {
    char *p = (char *)out, *end = (char *)out + cap;
    bulk_t *bp = (bulk_t *)XCORE_BULK_ADDR;
    if (!bulk_valid(bp))
        return (int)(ps_str(p, end, "bulkperf: pool not up (CM4 producer idle)\n") - (char *)out);

    volatile uint32_t *burst = (volatile uint32_t *)XCORE_BULK_BURST_ADDR;
    *burst = 1u; /* ask the CM4 to burst */
    __asm__ volatile("dmb" ::: "memory");
    uint32_t blocks = 0u, blen = 0u;
    int idx;
    uint64_t t0 = board_now_us();
    do { /* clock checked every iteration so a never-empty pool can't wedge the loop */
        idx = bulk_take(bp, &blen);
        if (idx >= 0) {
            bulk_release(bp, (uint32_t)idx);
            blocks++;
        }
    } while (board_now_us() - t0 < 200000u); /* 0.2 s window */
    uint64_t us = board_now_us() - t0;
    __asm__ volatile("dmb" ::: "memory");
    *burst = 0u; /* stop the CM4 burst */

    /* Resync the shared integrity state before the paced demo resumes. bulkperf shares the pool +
     * counters with xcore_bulk_consume: the CM4 can publish one residual WORD-pattern block after it
     * passes its while(*burst) check (xcore_bulk_consume would count it rx_bad), and g_bulk_tx_seq
     * jumped ~blocks during the burst (which would show as one huge rx_gap on the next paced block).
     * Let the CM4 land its last block, drain the pool, and re-baseline the consumer (codex #235). */
    uint64_t tq = board_now_us();
    while (board_now_us() - tq < 2000u) { /* > one CM4 produce */ }
    {
        uint32_t rl = 0u;
        int ri;
        while ((ri = bulk_take(bp, &rl)) >= 0) {
            bulk_release(bp, (uint32_t)ri);
        }
    }
    xcore_bulk_resync(); /* the next paced block re-baselines s_rx_last: no phantom gap or bad */

    uint32_t blk_s  = us ? (uint32_t)((uint64_t)blocks * 1000000u / us) : 0u;
    uint32_t kb_s   = us ? (uint32_t)((uint64_t)blocks * 256u * 1000u / us) : 0u;
    uint32_t mib_s  = us ? (uint32_t)((uint64_t)blocks * 256u * 1000000u / us / 1048576u) : 0u;
    uint32_t ns_blk = blocks ? (uint32_t)((uint64_t)us * 1000u / blocks) : 0u;

    p = ps_str(p, end, "bulkperf: 256B cross-core CM4->CM7, burst\n");
    p = ps_u32(p, end, blocks);       p = ps_str(p, end, " blk in ");
    p = ps_u32(p, end, (uint32_t)us); p = ps_str(p, end, " us\n");
    p = ps_u32(p, end, blk_s);        p = ps_str(p, end, " blk/s  ");
    p = ps_u32(p, end, kb_s);         p = ps_str(p, end, " KB/s  ");
    p = ps_u32(p, end, mib_s);        p = ps_str(p, end, " MiB/s\n");
    p = ps_u32(p, end, ns_blk);       p = ps_str(p, end, " ns/blk\n");
    return (int)(p - (char *)out);
}

/* xcore_clocks_ready — the boot handshake's CM7 half: written once after board_clock_init,
 * releasing the parked CM4 (its SysTick assumes the final 200 MHz HCLK).
 *
 * The wide window is zeroed FIRST: the comm thread may poll a wide channel before the
 * satellite's boot has run xcore_xw_init, and an uninitialized SRAM `words` field would
 * otherwise be trusted as a copy bound (codex #211). Zeroed, every pre-init poll reads
 * latest == 0 -> "nothing published" — and xioc_n_read additionally clamps the bound.
 * Config-independent: the whole XCORE_XW_MAX window, not the generated layout. */
static uint32_t g_layout_req; /* this owner boot's nonce (we also own the REQ cell) */

void xcore_clocks_ready(void) {
    /* The owner NEVER touches the wide window — channel init is exclusively the
     * WRITER's (satellite) job, and the layout handshake is the owner's barrier
     * (codex #211 r5-r7). The handshake is two SPSC cells (xcore.h): the owner bumps
     * its RETAINED req nonce here — one writer, this core — which instantly stales
     * every previous acknowledgement; a live same-build satellite re-acks within
     * ~one service tick, a stale or stopped one never does. */
    g_layout_req = (*(volatile uint32_t *)XCORE_LAYOUT_REQ_ADDR + 1u) | 1u;
    *(volatile uint32_t *)XCORE_LAYOUT_REQ_ADDR = g_layout_req;
    __asm__ volatile("dsb");
    /* Clock HSEM before releasing the CM4: the cross-core bulk doorbell (IRQ125) rides it, and
     * the CM4 rings it the moment it starts publishing. Enabling the peripheral clock here — from
     * the CM7's RCC, which clocks it chip-wide (there is no separate C2 enable on this part) —
     * guarantees it is live before the satellite ever touches an HSEM register. CM7-side C1IER +
     * NVIC arming happens later in comm_rx_irq_enable; rings before that just don't wake anyone. */
    RCC->AHB4ENR |= RCC_AHB4ENR_HSEMEN;
    (void)RCC->AHB4ENR;
    /* Zero the cross-core CpuLoad slots BEFORE releasing the CM4: SRAM4 is retained across resets,
     * so an absent/never-started/hung satellite would otherwise leave a stale non-zero Core-N load
     * in the frame (codex #235 r2). A live satellite overwrites its slot each tick; an absent one
     * stays 0. */
    for (int c = 0; c < 8; c++) ((volatile uint16_t *)XCORE_LOAD_ADDR)[c] = 0u;
    /* Clear a retained bulkperf burst request too: if the CM7 reset while a burst was in flight,
     * the CM4 would otherwise stay in its while(*burst) loop forever after this boot (no FB, no
     * paced producer). SRAM4 is retained, so clear it before releasing the CM4 (codex #235 r3). */
    *(volatile uint32_t *)XCORE_BULK_BURST_ADDR = 0u;
    *(volatile uint32_t *)XCORE_CLK_ADDR = XCORE_CLK_MAGIC;
    __asm__ volatile("dsb");
}


#include "xioc.h"
#include "xcore_gen.h" /* generated: the cross-core slot contract (gen/xcore_gen.h) */
#define XCORE_POOL ((xioc_t *)XCORE_IOC_ADDR)
/* xcore_layout_ok — the cross-image layout handshake: the satellite publishes the
 * generated XCORE_LAYOUT_ID (a hash of the whole slot/offset map) after initializing its
 * channels; the owner polls nothing until the ids MATCH. A stale satellite image — any
 * renumbered pair slot, moved wide offset, or resized channel — presents the wrong id
 * and every remote signal reads as never-fresh, instead of slot cross-talk transmitting
 * signal A's data as signal B (codex #211 r5). */
/* ack encoding shared with the satellite: req ^ id, with 0 remapped — a (req, id) pair
 * XORing to exactly 0 would equal the retraction sentinel and read absent-satellite as
 * acked (codex #211 r16) */
static uint32_t layout_ack_encode(uint32_t req) {
    uint32_t a = req ^ XCORE_LAYOUT_ID;
    return a != 0u ? a : 0x4C594F31u; /* 'LYO1' */
}

int xcore_layout_ok(void) {
    if (*(volatile uint32_t *)XCORE_LAYOUT_ACK_ADDR != layout_ack_encode(g_layout_req)) {
        return 0; /* not acked for THIS owner boot + THIS build's layout */
    }
    /* acquire: pairs with the satellite's release dmb in xcore_layout_publish — without
     * this the channel loads that follow a match could be satisfied ahead of the flag
     * read and observe pre-init state (codex #211 r6) */
    __asm__ volatile("dmb" ::: "memory");
    return 1;
}


/* xcore_poll_n — the wide-channel (xioc_n) reader: rd_seq/dst are the CALLER's per-signal
 * state (the generated comm loop declares one seq + lane buffer per wide signal), so this
 * stays stateless — any number of wide channels, no static table to size. `words` is the
 * READER's build-time lane count: a channel whose shared geometry disagrees (a stale
 * satellite image after a partial reflash) reads as never-fresh instead of overrunning
 * the lane buffer (codex #211 r2). 1 = dst now holds a newer complete value; on 0 dst
 * is untouched (last-good retention). */
int xcore_poll_n(uint32_t off, uint32_t words, uint32_t *rd_seq, uint32_t *dst) {
	return xioc_n_read((xioc_n_t *)(XCORE_XW_ADDR + off), rd_seq, dst, words);
}

/* dtrace: the M7 half of the two-core trace handoff (xcore.h). Single writer per field:
 * we own req_seq/op, the satellite owns ack_seq/count and the snapshot buffer.
 *
 * The exchange doubles as the cross-core clock measurement (REQ-TRACE-011). Both cores
 * timestamp their records from their own free-running origin — we boot first and release the
 * CM4 later, so at any instant our clock reads MORE than its — and a dump of both is
 * uncomparable until that difference is known. We bracket the round trip (t1 = request
 * released, t3 = ack observed) around the satellite's own stamp (t2, written just before it
 * acks) and solve it the way any round-trip clock sync does: t2 sits somewhere in [t1, t3], so
 * the midpoint is the best estimate and half the round trip bounds the error. Re-measured on
 * every snapshot, so a CM4 that reset cannot be drawn against a stale offset. */
unsigned long trace_now_us(void);

static uint32_t g_trc_t1;    /* our clock when we released the request */
static uint32_t g_trc_t3;    /* our clock when we first observed the ack */
static int g_trc_have_t3;    /* a round trip completed since the last request */

void xcore_trace_req(uint32_t op) {
    volatile uint32_t *c = (volatile uint32_t *)XCORE_TRC_ADDR;
    c[1] = op;
    g_trc_have_t3 = 0; /* this request's round trip has not closed yet */
    /* Sample as late as possible before releasing: time spent here is time the bound must
     * cover. */
    g_trc_t1 = (uint32_t)trace_now_us();
    __asm__ volatile("dmb" ::: "memory");
    c[0] = c[0] + 1u; /* req_seq++ releases the request */
}

int xcore_trace_ready(void) {
    volatile uint32_t *c = (volatile uint32_t *)XCORE_TRC_ADDR;
    if (c[2] != c[0])
        return 0; /* ack has not caught up */
    /* Stamp t3 on the polling pass that FIRST sees the ack — a later pass would charge our own
     * poll interval to the satellite and inflate the bound. */
    if (!g_trc_have_t3) {
        g_trc_t3 = (uint32_t)trace_now_us();
        g_trc_have_t3 = 1;
    }
    return 1;
}

/* xcore_trace_offset — the satellite's clock minus ours, in µs, from the round trip that just
 * closed; *bound_us is half that round trip, the residual uncertainty the host should show
 * rather than round away. Returns 0 when no exchange has completed, so the caller emits no
 * correlation at all instead of claiming a 0 skew it never measured.
 *
 * All three stamps come from one clock each, so the u32 subtractions are modular and stay
 * correct across the ~71-minute wrap as long as the true offset fits in an int32 (~35 min) —
 * far beyond any plausible core-release delay. */
int xcore_trace_offset(int32_t *off_us, uint32_t *bound_us) {
    volatile uint32_t *c = (volatile uint32_t *)XCORE_TRC_ADDR;
    if (!g_trc_have_t3)
        return 0;
    uint32_t rtt = g_trc_t3 - g_trc_t1;
    uint32_t mid = g_trc_t1 + rtt / 2u; /* our clock at the satellite's best-estimate stamp */
    uint32_t raw = c[XCORE_TRC_SVC_IDX] - mid; /* modular u32 difference */
    /* The u32 us clocks wrap every ~71.6 min, so a satellite restart can alias ANY
     * modular difference back into range — a wide guard band still admits e.g. a 60-min
     * restart aliasing to +11.6 min (codex #207, round 2). Accept only offsets inside the
     * PLAUSIBLE release-skew window (bench measured ~50 ms; 60 s is generous), which
     * shrinks the alias exposure to restarts landing within +/-60 s of a 71.6-min
     * multiple. The residual alias is unfixable with 32-bit stamps — a 64-bit svc stamp
     * is the real close-out, noted in the bench queue. Out-of-window = refuse: the host
     * shows "not measured" rather than a confident lie. */
    if (raw > 60000000u && raw < 0xFFFFFFFFu - 60000000u) { /* |offset| > 60 s */
        return 0;
    }
    *off_us = (int32_t)raw;
    *bound_us = rtt / 2u;
    return 1;
}

uint32_t xcore_trace_count(void) {
    volatile uint32_t *c = (volatile uint32_t *)XCORE_TRC_ADDR;
    uint32_t n = c[3];
    return n > XCORE_TRC_MAX_REC ? XCORE_TRC_MAX_REC : n;
}

unsigned char *xcore_trace_buf(void) {
    return (unsigned char *)XCORE_TRC_BUF_ADDR;
}

/* xcore_poll — the owner-side reader (comm loop tx and/or the owner FB read path): 1 if slot i
 * has a value newer than the last poll (out params always hold the best-known value). Reader
 * state per slot is ONE static here, so a given slot must have a SINGLE owner reader thread —
 * loom2v's build_model rejects a 2nd owner reader (SPSC; per-FB reader state is rung 2c). */
int xcore_poll(int i, uint32_t *a, uint32_t *b) {
    static xioc_rd_t rd[XCORE_IOC_N];
    if (i < 0 || i >= XCORE_IOC_N) return 0;
    int fresh = xioc_read(&XCORE_POOL[i], &rd[i]);
    *a = rd[i].a;
    *b = rd[i].b;
    return fresh;
}

/* NOTE: m4sig / iocx / boot shell commands are h755_threadx-specific (M4 signal slots, the
 * boot request cell) and are NOT part of this node's [shell] (commands = ["bulkperf"]). They
 * were trimmed from this per-node copy — the domain shell is bulkperf + the built-in ps/bmc. */

/* The exec-change trace hooks (trace_hooks.c), bracketing the doorbell ISR as comm_glue.c
 * brackets the FDCAN Rx one — guarded the same way. */
extern void _tx_execution_isr_enter(void);
extern void _tx_execution_isr_exit(void);
extern void comm_wake(void); /* comm_glue.c: post the comm thread's wake semaphore */

/* IRQ125 = HSEM1: the cross-core bulk DOORBELL. The CM4 releases the doorbell semaphore after
 * each bulk publish (m4_glue.c), which raises this interrupt on the CM7, so the comm thread wakes
 * and drains the shared pool immediately instead of waiting out the comm_rx_wait timeout. Same
 * tiny-ISR shape as the FDCAN Rx one: clear the flag, post the wake semaphore, defer the work. */
volatile uint32_t g_bulk_doorbell_irqs = 0u; /* SWD-observable: proves the cross-core IRQ fires */
void HSEM1_IT_IRQHandler(void)
{
#ifdef TX_ENABLE_EXECUTION_CHANGE_NOTIFY
    _tx_execution_isr_enter();
#endif
    HSEM->C1ICR = 1u << XCORE_BULK_DOORBELL_SEM;  /* clear THIS core's pending flag for the semaphore */
    g_bulk_doorbell_irqs++;
    comm_wake();                            /* wake comm -> xcore_bulk_consume drains the block(s) */
#ifdef TX_ENABLE_EXECUTION_CHANGE_NOTIFY
    _tx_execution_isr_exit();
#endif
}

/* comm_glue.c calls this once, right after it creates the wake semaphore and arms FDCAN1, so
 * the doorbell ISR can post it. Enable CM7 notification on the doorbell semaphore and route
 * IRQ125 at the comm priority (single trace level — never nests SysTick/the Rx ISR). The HSEM
 * clock is already on (enabled in xcore_clocks_ready, before the CM4 was released). */
void comm_wake_sources_arm(void)
{
    HSEM->C1IER = 1u << XCORE_BULK_DOORBELL_SEM;
    NVIC_SetPriority(HSEM1_IRQn, 4u);
    NVIC_ClearPendingIRQ(HSEM1_IRQn); /* pristine start: drop any ring latched before arming */
    NVIC_EnableIRQ(HSEM1_IRQn);
}

/* --- [nvm] persistence storage map (docs/nvm.md) ---------------------------------
 * The journal's sector pair = the BANK-2 TAIL (sectors 6+7, carved OUT of the
 * CM4 link regions in cm4_*.ld). Placement honesty (docs/nvm.md "where it
 * lives"): bank-2 programs/erases never stall THIS core (M7 executes from
 * bank 1 — true read-while-write), but the M4 executes from the bank-2 HEAD,
 * and an intra-bank erase stalls its fetches for the erase duration. The
 * design accepts that because ERASES ONLY RUN IN THE NM QUIET WINDOW (the
 * append path never erases — v2 engine rule; the generated flush runs
 * erase_pending at the sleep edges, when the node is quiescing). The M4 is
 * NOT NM-aware: its handlers WILL overrun during that erase (seconds of
 * stalled fetches) — accepted for the demo load on a node entering sleep.
 * A real M4 workload that must run through sleep windows takes the
 * documented out: copy its ~30 KB image to RAM at boot (docs/nvm.md), or
 * park it via an xcore-cell handshake before the erase. Record APPENDS (32 B programs,
 * ~us) stall the M4 negligibly. DRY-CODED; the bench validates flash.c for
 * boot + NvM in one pass. Driver: boards/h755zi/flash.c (shared with the
 * bootloader — one driver, two customers). */
uint32_t nvm_map_a(void) { return 0x081C0000u; } /* bank 2, sector 6 */
uint32_t nvm_map_b(void) { return 0x081E0000u; } /* bank 2, sector 7 */
uint32_t nvm_map_size(void) { return 0x00020000u; } /* 128 KB each */

/* --- cross-core bulk CONSUMER (docs/bulk-transport.md, ecu.toml [[bulk]] "xfer") -----------
 * The CM7 half of the platform-owned bulk pool: the generated comm loop calls xcore_bulk_consume()
 * each service pass. The M4 produces seq-tagged 256 B blocks into the shared window; here we
 * drain every published block, recompute the seq-derived pattern, and count. No FB touches the
 * pool. Counters are SWD-observable (find them in build/app.map):
 *   g_bulk_rx_ok  — blocks taken AND byte-exact (the shared-window ring works cross-core)
 *   g_bulk_rx_bad — length/pattern mismatch (a torn or corrupt transfer — must stay 0)
 *   g_bulk_rx_gap — seq jumped (blocks dropped under backpressure; pairs with M4 g_bulk_tx_full)
 * A climbing g_bulk_rx_ok with g_bulk_rx_bad == 0 is the pass condition (REQ-BULK-003 on silicon). */
size_t xcore_bulk_base(void) { return (size_t)XCORE_BULK_ADDR; }

/* Cross-core CpuLoad (xcore.h XCORE_LOAD_ADDR): read a satellite core's per-mille load from its slot,
 * for the CpuLoad frame's per-core byte. Strong override of the weak 0 default in weak_irq.c. */
uint16_t xcore_load_get(int core) {
	return (core >= 0 && core < 8) ? ((volatile uint16_t *)XCORE_LOAD_ADDR)[core] : 0u;
}

uint32_t g_bulk_rx_ok  = 0;
uint32_t g_bulk_rx_bad = 0;
uint32_t g_bulk_rx_gap = 0;
static uint32_t s_rx_last = 0;
static int s_rx_started = 0;

/* bulkperf calls this after its burst to re-baseline the paced-demo integrity check: clearing
 * s_rx_started makes the next taken block set s_rx_last afresh (no phantom rx_gap from the burst's
 * ~N-block seq jump). bulkperf also drains the pool first, so no residual word-pattern block
 * reaches the byte-pattern verify below (codex #235). */
void xcore_bulk_resync(void) { s_rx_started = 0; }

void xcore_bulk_consume(void) {
	bulk_t *p = (bulk_t *)XCORE_BULK_ADDR;
	if (!bulk_valid(p)) {
		return; /* producer hasn't initialized the pool yet (attach handshake) */
	}
	uint32_t len = 0;
	int idx;
	while ((idx = bulk_take(p, &len)) >= 0) { /* drain all published blocks this pass */
		uint8_t *b = bulk_buf(p, (uint32_t)idx);
		uint32_t seq = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
		               ((uint32_t)b[3] << 24);
		int ok = (len == 256u);
		for (uint32_t i = 4; ok && i < 256u; i++) {
			if (b[i] != (uint8_t)(seq * XCORE_STRESS_K + i)) {
				ok = 0;
			}
		}
		if (ok) {
			/* count the NUMBER of skipped sequence numbers (blocks the M4 dropped on a full
			 * pool), not just the fact of a discontinuity — so g_bulk_rx_gap tracks the M4's
			 * g_bulk_tx_full. Blocks arrive in publish order (FIFO ring), so seq is monotonic. */
			if (s_rx_started && seq > s_rx_last + 1u) {
				g_bulk_rx_gap += seq - s_rx_last - 1u;
			}
			s_rx_last = seq;
			s_rx_started = 1;
			g_bulk_rx_ok++;
		} else {
			g_bulk_rx_bad++;
		}
		bulk_release(p, (uint32_t)idx);
	}
}
