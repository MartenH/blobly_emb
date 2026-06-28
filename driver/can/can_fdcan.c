#include "can_port.h"
#include <stm32h735xx.h> /* CMSIS register map only — no HAL */
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

/* Nominal bit timing: 16 tq/bit, sample point 87.5% (sync 1 + tseg1 13 + tseg2 2). */
#define TQ_PER_BIT 16u
#define NBRP   (BLOB_FDCAN_KCLK_HZ / (BLOB_FDCAN_BITRATE * TQ_PER_BIT))
#define NTSEG1 13u
#define NTSEG2 2u
#define NSJW   1u

/* Message-RAM slice per instance (in 32-bit words): 8-byte classic element =
 * 2 header words + 2 data words. */
#define RX0_ELMTS    8u
#define TX_ELMTS     8u
#define ELMT_WORDS   4u
#define REGION_WORDS ((RX0_ELMTS + TX_ELMTS) * ELMT_WORDS)

static FDCAN_GlobalTypeDef *inst(int idx) {
	switch (idx) {
	case 0:  return FDCAN1;
	case 1:  return FDCAN2;
	case 2:  return FDCAN3;
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

int blob_can_open(const char *name, int fd_mode) {
	int idx = (name && name[0]) ? (name[0] - '0') : 0;
	FDCAN_GlobalTypeDef *c = inst(idx);
	if (!c)
		return -1;
	/* Classic CAN only for now (FD = bigger elements + DBTP, a future extension).
	 * Reject an FD bus at open rather than silently downgrade it to classic. */
	if (fd_mode)
		return -1;

	uint32_t off = region_off(idx);

	/* zero our message-RAM slice */
	for (uint32_t i = 0; i < REGION_WORDS; i++)
		ram_at(off)[i] = 0;

	/* enter init + enable config change */
	c->CCCR |= FDCAN_CCCR_INIT;
	while ((c->CCCR & FDCAN_CCCR_INIT) == 0u) {
	}
	c->CCCR |= FDCAN_CCCR_CCE;
	c->CCCR &= ~(FDCAN_CCCR_FDOE | FDCAN_CCCR_BRSE); /* classic */

	c->NBTP = ((NSJW - 1u) << FDCAN_NBTP_NSJW_Pos) |
	          ((NTSEG1 - 1u) << FDCAN_NBTP_NTSEG1_Pos) |
	          ((NTSEG2 - 1u) << FDCAN_NBTP_NTSEG2_Pos) |
	          ((NBRP - 1u) << FDCAN_NBTP_NBRP_Pos);

	/* Accept non-matching STANDARD data frames into Rx FIFO0; reject extended-id
	 * and remote frames — this backend handles classic 11-bit data frames only, so
	 * recv() never has to deal with (and would mis-decode) other frame types. */
	c->GFC = FDCAN_GFC_RRFE | FDCAN_GFC_RRFS | (2u << FDCAN_GFC_ANFE_Pos);
	c->SIDFC = 0;

	/* Rx FIFO0 at the slice start; Tx FIFO right after it */
	uint32_t tx_off = off + RX0_ELMTS * ELMT_WORDS;
	c->RXF0C = (off << FDCAN_RXF0C_F0SA_Pos) | (RX0_ELMTS << FDCAN_RXF0C_F0S_Pos);
	c->RXESC = 0; /* F0DS = 0 -> 8-byte data */
	c->TXBC = (tx_off << FDCAN_TXBC_TBSA_Pos) | (TX_ELMTS << FDCAN_TXBC_TFQS_Pos);
	c->TXESC = 0; /* TBDS = 0 -> 8-byte data */

	/* leave init -> CAN core synchronizes to the bus */
	c->CCCR &= ~FDCAN_CCCR_INIT;
	while ((c->CCCR & FDCAN_CCCR_INIT) != 0u) {
	}
	return idx;
}

int blob_can_send(int h, uint32_t id, const uint8_t *data, uint8_t len, int fd_mode) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (!c || len > 8)
		return -1; /* classic frame */
	(void)fd_mode;
	if (c->TXFQS & FDCAN_TXFQS_TFQF)
		return -1; /* Tx FIFO full */

	uint32_t pi = (c->TXFQS & FDCAN_TXFQS_TFQPI) >> FDCAN_TXFQS_TFQPI_Pos;
	uint32_t tx_off = region_off(h) + RX0_ELMTS * ELMT_WORDS;
	volatile uint32_t *e = ram_at(tx_off + pi * ELMT_WORDS);

	e[0] = (id & 0x7FFu) << 18; /* T0: 11-bit std id, XTD/RTR/ESI = 0 */
	e[1] = (uint32_t)len << 16; /* T1: DLC = len (classic), no FDF/BRS */

	uint32_t w0 = 0, w1 = 0;
	for (uint8_t i = 0; i < len; i++) {
		if (i < 4)
			w0 |= (uint32_t)data[i] << (8u * i);
		else
			w1 |= (uint32_t)data[i] << (8u * (i - 4u));
	}
	e[2] = w0;
	e[3] = w1;

	c->TXBAR = (1u << pi); /* request transmission */
	return 0;
}

int blob_can_recv(int h, uint32_t *id, uint8_t *data, uint8_t *len) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (!c)
		return -1;
	uint32_t s = c->RXF0S;
	if ((s & FDCAN_RXF0S_F0FL) == 0u)
		return -1; /* FIFO0 empty */

	uint32_t gi = (s & FDCAN_RXF0S_F0GI) >> FDCAN_RXF0S_F0GI_Pos;
	volatile uint32_t *e = ram_at(region_off(h) + gi * ELMT_WORDS);

	uint32_t r0 = e[0], r1 = e[1];
	/* Classic standard data frames only. Extended-id (XTD) / remote (RTR) frames are
	 * already filtered by GFC; drop any that slip through rather than deliver a bogus
	 * id/payload. (XTD = R0 bit 30, RTR = R0 bit 29.) */
	if ((r0 & 0x40000000u) || (r0 & 0x20000000u)) {
		c->RXF0A = gi; /* acknowledge to advance the FIFO, then report no frame */
		return -1;
	}
	*id = (r0 >> 18) & 0x7FFu;       /* standard id */
	uint8_t n = (uint8_t)((r1 >> 16) & 0xFu); /* DLC */
	if (n > 8)
		n = 8; /* classic clamp */
	*len = n;

	uint32_t w0 = e[2], w1 = e[3];
	for (uint8_t i = 0; i < n; i++)
		data[i] = (uint8_t)((i < 4 ? (w0 >> (8u * i)) : (w1 >> (8u * (i - 4u)))) & 0xFFu);

	c->RXF0A = gi; /* acknowledge -> advance the FIFO */
	return 0;
}

void blob_can_close(int h) {
	FDCAN_GlobalTypeDef *c = inst(h);
	if (c)
		c->CCCR |= FDCAN_CCCR_INIT; /* stop participating on the bus */
}
