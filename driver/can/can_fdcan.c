#include "can_port.h"
#include <stm32h7xx.h> /* CMSIS family dispatcher (build sets -DSTM32H735xx / -DSTM32H755xx); no HAL */
#include <string.h>

/* Bare-metal FDCAN (Bosch M_CAN) backend for STM32 H7 — register-level, no HAL.
 *
 * Classic CAN, 500 kbit/s by default. Each FDCAN instance gets its own slice of
 * the shared message RAM (SRAMCAN): an 8-deep Rx FIFO0 (accept-all) and an
 * 8-deep Tx FIFO, 8-byte elements. The init sequence mirrors ST's HAL
 * (stm32h7xx_hal_fdcan.c) but emits direct register writes.
 *
 * Contract: the board brings up the peripheral *around* the M_CAN core before
 * blob_can_open() — enable the FDCAN APB clock, select+enable the kernel clock
 * (must equal BLOB_FDCAN_KCLK_HZ), and mux the TX/RX pins to their AF. This file
 * only configures and drives the M_CAN core. See examples/h735_canecho/board.c.
 */

#ifndef BLOB_FDCAN_KCLK_HZ
#define BLOB_FDCAN_KCLK_HZ 80000000u /* FDCAN kernel clock (board must match) */
#endif
#ifndef BLOB_FDCAN_BITRATE
#define BLOB_FDCAN_BITRATE 500000u
#endif

/* Nominal bit timing. Defaults give 16 tq/bit at an 87.5% sample point
 * (sync 1 + tseg1 13 + tseg2 2), valid when the kernel clock is a multiple of
 * bitrate*16. A board whose kernel clock isn't (e.g. the H735-DK's 25 MHz HSE)
 * overrides these so the prescaler stays integer — e.g. 25 MHz / 500 kbit needs
 * 10 tq (tseg1 7 + tseg2 2, NBRP 5, 80% sample). */
#ifndef BLOB_FDCAN_TQ
#define BLOB_FDCAN_TQ 16u
#endif
#ifndef BLOB_FDCAN_NTSEG1
#define BLOB_FDCAN_NTSEG1 13u
#endif
#ifndef BLOB_FDCAN_NTSEG2
#define BLOB_FDCAN_NTSEG2 2u
#endif
#ifndef BLOB_FDCAN_NSJW
#define BLOB_FDCAN_NSJW 1u
#endif
#define NBRP   (BLOB_FDCAN_KCLK_HZ / (BLOB_FDCAN_BITRATE * BLOB_FDCAN_TQ))
#define NTSEG1 BLOB_FDCAN_NTSEG1
#define NTSEG2 BLOB_FDCAN_NTSEG2
#define NSJW   BLOB_FDCAN_NSJW

/* CAN-FD data-phase (BRS) bit timing — only used when a bus is opened in FD mode.
 * Defaults give 2 Mbit/s at an 80% sample point on an 80 MHz kernel clock (20 tq:
 * sync 1 + dtseg1 15 + dtseg2 4, DBRP 2). A board whose kernel clock isn't a
 * multiple of dbitrate*dtq overrides these so the prescaler stays integer (same
 * as the nominal NBTP overrides). */
#ifndef BLOB_FDCAN_DBITRATE
#define BLOB_FDCAN_DBITRATE 2000000u
#endif
#ifndef BLOB_FDCAN_DTQ
#define BLOB_FDCAN_DTQ 20u
#endif
#ifndef BLOB_FDCAN_DTSEG1
#define BLOB_FDCAN_DTSEG1 15u
#endif
#ifndef BLOB_FDCAN_DTSEG2
#define BLOB_FDCAN_DTSEG2 4u
#endif
#ifndef BLOB_FDCAN_DSJW
#define BLOB_FDCAN_DSJW 4u
#endif
#define DBRP   (BLOB_FDCAN_KCLK_HZ / (BLOB_FDCAN_DBITRATE * BLOB_FDCAN_DTQ))
#define DTSEG1 BLOB_FDCAN_DTSEG1
#define DTSEG2 BLOB_FDCAN_DTSEG2
#define DSJW   BLOB_FDCAN_DSJW

/* Message-RAM slice per instance (in 32-bit words). Elements are sized for a full
 * 64-byte CAN-FD payload = 2 header words + 16 data words, uniformly for every
 * instance so the per-instance offset (idx * REGION_WORDS) stays simple; a classic
 * 8-byte frame just uses the first two data words. 3 * 288 = 864 words fits the
 * shared 2560-word (10 KB) SRAMCAN. */
#define RX0_ELMTS    8u
#define TX_ELMTS     8u
#define ELMT_WORDS   18u
#define REGION_WORDS ((RX0_ELMTS + TX_ELMTS) * ELMT_WORDS)

/* CAN-FD data-length-code <-> byte-count. DLC 0-8 = 0-8 bytes; 9-15 = 12,16,20,
 * 24,32,48,64. len_to_dlc rounds a non-standard length up to the next code (the
 * extra bytes are transmitted as zero padding). */
static uint8_t dlc_to_len(uint8_t dlc) {
	static const uint8_t t[16] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64 };
	return t[dlc & 0xFu];
}
static uint8_t len_to_dlc(uint8_t len) {
	if (len <= 8u)  return len;
	if (len <= 12u) return 9u;
	if (len <= 16u) return 10u;
	if (len <= 20u) return 11u;
	if (len <= 24u) return 12u;
	if (len <= 32u) return 13u;
	if (len <= 48u) return 14u;
	return 15u; /* <= 64 */
}

static FDCAN_GlobalTypeDef *inst(int idx) {
	switch (idx) {
	case 0:  return FDCAN1;
	case 1:  return FDCAN2;
#ifdef FDCAN3
	case 2:  return FDCAN3; /* only on 3-FDCAN parts (H72x/H73x); absent on H74x/H75x */
#endif
	default: return 0;
	}
}

/* word offset of this instance's slice within SRAMCAN, and a pointer into it */
static uint32_t region_off(int idx) {
	return (uint32_t)idx * REGION_WORDS;
}
static volatile uint32_t *ram_at(uint32_t word_off) {
	return (volatile uint32_t *)(SRAMCAN_BASE + word_off * 4u);
}

/* Rx-FIFO0 overrun EVENTS per FDCAN instance (idx 0..2). The M_CAN sets IR.RF0L when a
 * frame arrives with FIFO0 full and is DROPPED — receive-with-loss beyond capacity. RF0L
 * is a single sticky flag, not a lost-frame count, so this counts OCCURRENCES (each is
 * >=1 frame lost): a monotonic loss indicator, not an exact frame total. Surfaced via
 * blob_can_rx_overruns() so the loss is observable, not silent (REQ-CAN-DRV-008). */
static uint32_t g_rx_lost[3];

/* Per-instance CAN-FD capability, latched at open(): send() only emits an FD frame
 * (FDF/BRS + >8-byte payload) on a bus that was opened in FD mode. */
static uint8_t g_fd[3];

int blob_can_open(const char *name, int fd_mode) {
	int idx = (name && name[0]) ? (name[0] - '0') : 0;
	FDCAN_GlobalTypeDef *c = inst(idx);
	if (!c)
		return -1;
	if (idx >= 0 && idx < 3)
		g_fd[idx] = fd_mode ? 1u : 0u;

	uint32_t off = region_off(idx);

	/* zero our message-RAM slice */
	for (uint32_t i = 0; i < REGION_WORDS; i++)
		ram_at(off)[i] = 0;

	/* enter init + enable config change. Bounded: if the core never acknowledges
	 * INIT (e.g. the FDCAN kernel clock is misconfigured), fail open() rather than
	 * hang the ECU at startup. */
	c->CCCR |= FDCAN_CCCR_INIT;
	for (uint32_t t = 0; (c->CCCR & FDCAN_CCCR_INIT) == 0u; t++) {
		if (t >= 1000000u)
			return -1;
	}
	c->CCCR |= FDCAN_CCCR_CCE;
	if (fd_mode) {
		/* Fail loudly (return -1) rather than program a mistimed FD data phase: the board
		 * must pick BLOB_FDCAN_D* so the kernel clock divides EXACTLY (an integer prescaler
		 * in 1..32 — a fractional divide would silently shift the data bitrate) and the
		 * segments sum to the bit time. Same discipline the nominal N* timing already needs. */
		if (DBRP < 1u || DBRP > 32u
		    || (BLOB_FDCAN_KCLK_HZ % (BLOB_FDCAN_DBITRATE * BLOB_FDCAN_DTQ)) != 0u
		    || (1u + DTSEG1 + DTSEG2) != BLOB_FDCAN_DTQ)
			return -1;
		c->CCCR |= FDCAN_CCCR_FDOE | FDCAN_CCCR_BRSE; /* CAN-FD, bit-rate switching */
		c->DBTP = ((DSJW - 1u) << FDCAN_DBTP_DSJW_Pos) |
		          ((DTSEG1 - 1u) << FDCAN_DBTP_DTSEG1_Pos) |
		          ((DTSEG2 - 1u) << FDCAN_DBTP_DTSEG2_Pos) |
		          ((DBRP - 1u) << FDCAN_DBTP_DBRP_Pos);
	} else {
		c->CCCR &= ~(FDCAN_CCCR_FDOE | FDCAN_CCCR_BRSE); /* classic */
	}

	c->NBTP = ((NSJW - 1u) << FDCAN_NBTP_NSJW_Pos) |
	          ((NTSEG1 - 1u) << FDCAN_NBTP_NTSEG1_Pos) |
	          ((NTSEG2 - 1u) << FDCAN_NBTP_NTSEG2_Pos) |
	          ((NBRP - 1u) << FDCAN_NBTP_NBRP_Pos);

	/* Accept non-matching STANDARD and EXTENDED data frames into Rx FIFO0 (ANFS/ANFE
	 * = 0); reject REMOTE frames (RRFS/RRFE) — this backend handles classic data frames
	 * of either id width, and recv() reports the width via BLOB_CAN_FLAG_EXT. */
	c->GFC = FDCAN_GFC_RRFE | FDCAN_GFC_RRFS;
	c->SIDFC = 0;

	/* Rx FIFO0 at the slice start; Tx FIFO right after it */
	uint32_t tx_off = off + RX0_ELMTS * ELMT_WORDS;
	c->RXF0C = (off << FDCAN_RXF0C_F0SA_Pos) | (RX0_ELMTS << FDCAN_RXF0C_F0S_Pos);
	c->RXESC = (7u << FDCAN_RXESC_F0DS_Pos); /* F0DS = 7 -> 64-byte data element */
	c->TXBC = (tx_off << FDCAN_TXBC_TBSA_Pos) | (TX_ELMTS << FDCAN_TXBC_TFQS_Pos);
	c->TXESC = (7u << FDCAN_TXESC_TBDS_Pos); /* TBDS = 7 -> 64-byte data element */

	/* Fresh session: clear any stale message-lost flag + the overrun tally so a
	 * close/reopen of this bus doesn't report the previous session's losses. */
	c->IR = FDCAN_IR_RF0L;
	if (idx >= 0 && idx < 3)
		g_rx_lost[idx] = 0;

	/* leave init -> CAN core synchronizes to the bus (bounded, same as above). */
	c->CCCR &= ~FDCAN_CCCR_INIT;
	for (uint32_t t = 0; (c->CCCR & FDCAN_CCCR_INIT) != 0u; t++) {
		if (t >= 1000000u)
			return -1;
	}
	return idx;
}

int blob_can_send(int h, uint32_t id, const uint8_t *data, uint8_t len, int flags) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (!c)
		return -1;
	int fd = (flags & BLOB_CAN_FLAG_FD) ? 1 : 0;
	if (fd && !(h >= 0 && h < 3 && g_fd[h]))
		return -1; /* an FD frame was requested on a classic-configured bus */
	if (!fd && len > 8)
		return -1; /* a classic frame cannot exceed 8 bytes */
	if (len > 64)
		return -1;
	/* Only an exact CAN-FD data length (0-8, 12,16,20,24,32,48,64) is representable. Reject a
	 * non-canonical length (9-11, 13-15, ...) rather than pad up to the next code: the rx side
	 * matches the literal DBC length, so padding would change the frame's on-wire length and
	 * get it discarded. Mirrors dlc_exact() in the st-hal backend. */
	if (dlc_to_len(len_to_dlc(len)) != len)
		return -1;
	/* Non-blocking: report FIFO-full to the caller instead of spinning here. A caller
	 * that bursts more than the 8-deep Tx FIFO (e.g. the ISO-TP trace dump) gates on
	 * blob_can_tx_ready() and paces itself, so the driver never blocks the loop/thread. */
	if (c->TXFQS & FDCAN_TXFQS_TFQF)
		return -1; /* Tx FIFO full */

	uint32_t pi = (c->TXFQS & FDCAN_TXFQS_TFQPI) >> FDCAN_TXFQS_TFQPI_Pos;
	if (pi >= TX_ELMTS)
		return -1; /* out-of-range index from a misbehaving peripheral: never write past our slice */
	uint32_t tx_off = region_off(h) + RX0_ELMTS * ELMT_WORDS;
	volatile uint32_t *e = ram_at(tx_off + pi * ELMT_WORDS);

	if (flags & BLOB_CAN_FLAG_EXT)
		e[0] = (id & 0x1FFFFFFFu) | (1u << 30); /* T0: 29-bit ext id, XTD=1 (bit30) */
	else
		e[0] = (id & 0x7FFu) << 18; /* T0: 11-bit std id, XTD/RTR/ESI = 0 */
	uint8_t dlc = fd ? len_to_dlc(len) : len;
	/* T1: DLC [19:16]; FD frames set FDF (bit21) + BRS (bit20). */
	e[1] = ((uint32_t)dlc << 16) | (fd ? ((1u << 21) | (1u << 20)) : 0u);

	/* Write the padded data length (dlc_to_len rounds a non-standard len up to the
	 * next code); bytes past the caller's len are zero. Up to 16 words for 64 bytes. */
	uint8_t plen = dlc_to_len(dlc);
	for (uint8_t w = 0; w < (plen + 3u) / 4u; w++) {
		uint32_t word = 0;
		for (uint8_t b = 0; b < 4u; b++) {
			uint8_t bi = (uint8_t)(w * 4u + b);
			uint8_t v = (bi < len) ? data[bi] : 0u;
			word |= (uint32_t)v << (8u * b);
		}
		e[2 + w] = word;
	}

	c->TXBAR = (1u << pi); /* request transmission */
	return 0;
}

/* Non-blocking backpressure query: 1 if the Tx FIFO can accept a frame now, else 0.
 * A burst sender (the ISO-TP dump) gates on this so it never overruns the FIFO or
 * blocks — it sends up to a FIFO's worth per pass and resumes on the next. */
int blob_can_tx_ready(int h) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (!c)
		return 0;
	return (c->TXFQS & FDCAN_TXFQS_TFQF) ? 0 : 1;
}

/* Wire-done, not software-done: TXBRP holds a bit per Tx buffer with a transmission
 * REQUESTED but not yet completed. 0 means every frame handed to the controller has
 * actually left (or was cancelled). The boot manager gates its self-reset on this so
 * the 0x11 positive response isn't lost mid-controller (REQ-BOOT-012). */
int blob_can_tx_idle(int h) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (!c)
		return 1;
	return c->TXBRP == 0u;
}

int blob_can_recv(int h, uint32_t *id, uint8_t *data, uint8_t *len, int *flags) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (!c)
		return -1;
	/* Note any FIFO0 overrun since the last drain, then acknowledge it (write-1-clear),
	 * before the empty-check below so a loss that left the FIFO drained is still counted. */
	if ((c->IR & FDCAN_IR_RF0L) && h >= 0 && h < 3) {
		g_rx_lost[h]++;
		c->IR = FDCAN_IR_RF0L;
	}
	uint32_t s = c->RXF0S;
	if ((s & FDCAN_RXF0S_F0FL) == 0u)
		return -1; /* FIFO0 empty */

	uint32_t gi = (s & FDCAN_RXF0S_F0GI) >> FDCAN_RXF0S_F0GI_Pos;
	if (gi >= RX0_ELMTS)
		return -1; /* out-of-range index from a misbehaving peripheral: don't read past our slice */
	volatile uint32_t *e = ram_at(region_off(h) + gi * ELMT_WORDS);

	uint32_t r0 = e[0], r1 = e[1];
	/* Classic data frames, standard OR extended id. Drop REMOTE (RTR) frames — they are
	 * obsolete and carry no payload (RTR = R0 bit 29). XTD = R0 bit 30 selects the id
	 * width: 29-bit ext id in bits 28:0, else 11-bit std id in bits 28:18. */
	if (r0 & 0x20000000u) {
		c->RXF0A = gi; /* remote frame: acknowledge to advance the FIFO, report no frame */
		return -1;
	}
	*flags = 0;
	if (r0 & 0x40000000u) {
		*id = r0 & 0x1FFFFFFFu; /* extended id */
		*flags |= BLOB_CAN_FLAG_EXT;
	} else {
		*id = (r0 >> 18) & 0x7FFu; /* standard id */
	}
	uint8_t dlc = (uint8_t)((r1 >> 16) & 0xFu);
	int fd = (r1 & (1u << 21)) ? 1 : 0; /* FDF: this is a CAN-FD frame */
	uint8_t n = fd ? dlc_to_len(dlc) : (dlc > 8u ? 8u : dlc);
	if (n > 64u)
		n = 64u;
	*len = n;
	if (fd)
		*flags |= BLOB_CAN_FLAG_FD;

	/* up to 16 data words (64 bytes); e[2] is the first */
	for (uint8_t i = 0; i < n; i++)
		data[i] = (uint8_t)((e[2 + (i >> 2)] >> (8u * (i & 3u))) & 0xFFu);

	c->RXF0A = gi; /* acknowledge -> advance the FIFO */
	return 0;
}

/* Count of Rx-FIFO0 overrun events since open (see g_rx_lost) — each event is >=1 frame
 * lost; the upper layer polls this to observe receive-with-loss instead of it being
 * silent. Monotonic within a session; reset by open(). */
uint32_t blob_can_rx_overruns(int h) {
	return (h >= 0 && h < 3) ? g_rx_lost[h] : 0u;
}

void blob_can_close(int h) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (c)
		c->CCCR |= FDCAN_CCCR_INIT; /* stop participating on the bus */
}
