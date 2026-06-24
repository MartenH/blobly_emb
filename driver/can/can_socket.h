#ifndef BLOBLY_CAN_SOCKET_H
#define BLOBLY_CAN_SOCKET_H
#include <stdint.h>

/* Thin SocketCAN shim for the host/sim build of the CAN driver port.
 * The target build replaces this file with the MCAL/vendor HAL backend;
 * the V side (driver/can/can.v) stays identical. */

int  blob_can_open(const char *ifname, int fd_mode); /* returns socket fd, or -1 */
int  blob_can_send(int sock, uint32_t id, const uint8_t *data, uint8_t len);
int  blob_can_recv(int sock, uint32_t *id, uint8_t *data, uint8_t *len); /* 0=frame, -1=none */
void blob_can_close(int sock);

#endif
