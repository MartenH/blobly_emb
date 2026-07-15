#ifndef BLOBLY_CAN_PORT_H
#define BLOBLY_CAN_PORT_H
#include <stdint.h>

/* CAN / CAN-FD driver PORT — the narrow contract the COM bridge depends on.
 *
 * The V side (driver/can/can.v) calls exactly these four functions; each
 * platform provides ONE implementation, selected at build time in can_backend.c:
 *
 *   (default)          host / sim    SocketCAN over vcan      (can_socket.c)
 *   -DBLOB_CAN_STHAL   STM32 H7      FDCAN via ST HAL         (can_sthal.c)
 *   -DBLOB_CAN_CANIF   AUTOSAR ECU   above CanIf as a CDD     (can_canif.c)
 *
 * `name` identifies the bus: a netdev ("vcan0") on SocketCAN, a bus index
 * ("0".."2") on the target backends. `fd_mode` selects CAN-FD vs classic.
 * Frames are fixed-size value types and all buffers are static — no heap.
 *
 * The contract is POLLED on purpose: the whole bridge is tick-driven, so
 * recv() returns the next queued frame or "none". Callback-driven stacks
 * (AUTOSAR CanIf RxIndication, an FDCAN Rx ISR) adapt by pushing into a
 * single-producer/single-consumer ring (can_ring.h) that recv() drains — so
 * application code never runs in ISR/BSW context. */

int      blob_can_open(const char *name, int fd_mode);                    /* >=0 handle, -1 fail */
int      blob_can_send(int h, uint32_t id, const uint8_t *data, uint8_t len, int fd_mode);
int      blob_can_tx_ready(int h);                                        /* 1=Tx can accept now, 0=full */
int      blob_can_tx_idle(int h);                                         /* 1=all handed-off frames transmitted */
int      blob_can_recv(int h, uint32_t *id, uint8_t *data, uint8_t *len); /* 0=frame, -1=none */
uint32_t blob_can_rx_overruns(int h);  /* count of Rx-overrun events since open, each >=1 frame lost (REQ-CAN-DRV-008) */
void     blob_can_close(int h);

#endif
