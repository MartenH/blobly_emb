#include "can_port.h"
#include "stm32h7xx_hal.h"
#include <string.h>

/* CAN-FD backend for STM32 H7 over the ST HAL — bare-metal, no AUTOSAR.
 *
 * On the STM32H735G-DK the three FDCAN instances are wired to onboard 3V3
 * CAN-FD transceivers brought out to the board edge, so bus "0".."2" map
 * straight to a physical CAN-FD connector with no extra Click/transceiver.
 *
 * Clock tree, GPIO AF, and bit timing (nominal + data) are set up by CubeMX in
 * the app's startup (MX_FDCANx_Init, called from main.v before gen.run); this
 * backend only starts/stops the peripheral and moves frames. recv() polls Rx
 * FIFO0, matching the bridge's polled tick — no ISR needed for first bring-up
 * (switch to the IRQ + can_ring.h path later for lower latency). */

extern FDCAN_HandleTypeDef hfdcan1;
extern FDCAN_HandleTypeDef hfdcan2;
extern FDCAN_HandleTypeDef hfdcan3;

static FDCAN_HandleTypeDef *bus_handle(int idx) {
	switch (idx) {
	case 0:  return &hfdcan1;
	case 1:  return &hfdcan2;
	case 2:  return &hfdcan3;
	default: return 0;
	}
}

/* A length is representable only as an exact CAN/CAN-FD DLC: 0..8, or
 * 12,16,20,24,32,48,64. A length like 9..11 would be padded up to the next DLC
 * here, but the generated bridge matches the literal DBC length on rx, so the
 * frame would be discarded. Reject it instead of silently changing the length. */
static int dlc_exact(uint8_t len) {
	if (len <= 8)
		return 1;
	switch (len) {
	case 12:
	case 16:
	case 20:
	case 24:
	case 32:
	case 48:
	case 64:
		return 1;
	default:
		return 0;
	}
}

/* byte count <-> HAL DLC code (the code lives in bits [19:16] of DataLength). */
static uint32_t len_to_dlc(uint8_t len) {
	if (len <= 8)  return (uint32_t)len << 16;   /* FDCAN_DLC_BYTES_0..8 */
	if (len <= 12) return FDCAN_DLC_BYTES_12;
	if (len <= 16) return FDCAN_DLC_BYTES_16;
	if (len <= 20) return FDCAN_DLC_BYTES_20;
	if (len <= 24) return FDCAN_DLC_BYTES_24;
	if (len <= 32) return FDCAN_DLC_BYTES_32;
	if (len <= 48) return FDCAN_DLC_BYTES_48;
	return FDCAN_DLC_BYTES_64;
}
static uint8_t dlc_to_len(uint32_t dlc) {
	switch (dlc) {
	case FDCAN_DLC_BYTES_12: return 12;
	case FDCAN_DLC_BYTES_16: return 16;
	case FDCAN_DLC_BYTES_20: return 20;
	case FDCAN_DLC_BYTES_24: return 24;
	case FDCAN_DLC_BYTES_32: return 32;
	case FDCAN_DLC_BYTES_48: return 48;
	case FDCAN_DLC_BYTES_64: return 64;
	default: return (uint8_t)(dlc >> 16);        /* 0..8 */
	}
}

/* Rx-FIFO0 overrun events per instance (idx 0..2): each is >=1 frame lost (REQ-CAN-DRV-008). */
static uint32_t rx_lost[3];

int blob_can_open(const char *name, int fd_mode) {
	int idx = (name && name[0]) ? (name[0] - '0') : 0;
	FDCAN_HandleTypeDef *hf = bus_handle(idx);
	if (!hf) return -1;
	(void)fd_mode; /* classic vs FD is fixed by the CubeMX bit-timing init */
	/* Accept all ids into FIFO0; tighten with hardware filters in MX init if wanted. */
	HAL_FDCAN_ConfigGlobalFilter(hf, FDCAN_ACCEPT_IN_RX_FIFO0, FDCAN_ACCEPT_IN_RX_FIFO0,
	                             FDCAN_REJECT_REMOTE, FDCAN_REJECT_REMOTE);
	if (HAL_FDCAN_Start(hf) != HAL_OK) return -1;
	/* Fresh session: clear a stale message-lost flag + the tally so a close/reopen of this
	 * bus doesn't report the previous session's overruns ("since open"). */
	__HAL_FDCAN_CLEAR_FLAG(hf, FDCAN_FLAG_RX_FIFO0_MESSAGE_LOST);
	if (idx >= 0 && idx < 3)
		rx_lost[idx] = 0;
	return idx;
}

int blob_can_send(int h, uint32_t id, const uint8_t *data, uint8_t len, int fd_mode) {
	FDCAN_HandleTypeDef *hf = bus_handle(h);
	if (!hf) return -1;
	if (!dlc_exact(len)) return -1; /* don't pad to a different on-wire length */
	FDCAN_TxHeaderTypeDef tx;
	tx.Identifier          = id & 0x1FFFFFFFu;
	tx.IdType              = (id > 0x7FFu) ? FDCAN_EXTENDED_ID : FDCAN_STANDARD_ID;
	tx.TxFrameType         = FDCAN_DATA_FRAME;
	tx.DataLength          = len_to_dlc(len);
	tx.ErrorStateIndicator = FDCAN_ESI_ACTIVE;
	tx.BitRateSwitch       = fd_mode ? FDCAN_BRS_ON : FDCAN_BRS_OFF;
	tx.FDFormat            = fd_mode ? FDCAN_FD_CAN : FDCAN_CLASSIC_CAN;
	tx.TxEventFifoControl  = FDCAN_NO_TX_EVENTS;
	tx.MessageMarker       = 0;
	if (HAL_FDCAN_AddMessageToTxFifoQ(hf, &tx, (uint8_t *)data) != HAL_OK) return -1;
	return 0;
}

/* 1 if the Tx FIFO queue has a free slot — the burst sender gates on this so it never
 * overruns the FIFO or blocks. */
int blob_can_tx_ready(int h) {
	FDCAN_HandleTypeDef *hf = bus_handle(h);
	return (hf && HAL_FDCAN_GetTxFifoFreeLevel(hf) > 0) ? 1 : 0;
}

int blob_can_recv(int h, uint32_t *id, uint8_t *data, uint8_t *len) {
	FDCAN_HandleTypeDef *hf = bus_handle(h);
	if (!hf) return -1;
	/* Note + clear a FIFO0 message-lost since the last drain, before the empty-check, so a
	 * loss that left the FIFO drained is still counted (REQ-CAN-DRV-008). */
	if (__HAL_FDCAN_GET_FLAG(hf, FDCAN_FLAG_RX_FIFO0_MESSAGE_LOST) && h >= 0 && h < 3) {
		rx_lost[h]++;
		__HAL_FDCAN_CLEAR_FLAG(hf, FDCAN_FLAG_RX_FIFO0_MESSAGE_LOST);
	}
	if (HAL_FDCAN_GetRxFifoFillLevel(hf, FDCAN_RX_FIFO0) == 0) return -1;
	FDCAN_RxHeaderTypeDef rx;
	if (HAL_FDCAN_GetRxMessage(hf, FDCAN_RX_FIFO0, &rx, data) != HAL_OK) return -1;
	*id  = rx.Identifier;
	*len = dlc_to_len(rx.DataLength);
	return 0;
}

/* Rx-FIFO0 overrun events since open — recv() samples FDCAN_FLAG_RX_FIFO0_MESSAGE_LOST
 * and accumulates it here (REQ-CAN-DRV-008). */
uint32_t blob_can_rx_overruns(int h) {
	return (h >= 0 && h < 3) ? rx_lost[h] : 0u;
}

void blob_can_close(int h) {
	FDCAN_HandleTypeDef *hf = bus_handle(h);
	if (hf) HAL_FDCAN_Stop(hf);
}
