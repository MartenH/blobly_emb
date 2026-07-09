#include "can_port.h"
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/can.h>
#include <linux/can/raw.h>

int blob_can_open(const char *ifname, int fd_mode) {
	int s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
	if (s < 0) return -1;

	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(s, SIOCGIFINDEX, &ifr) < 0) { close(s); return -1; }

	if (fd_mode) {
		int enable = 1;
		setsockopt(s, SOL_CAN_RAW, CAN_RAW_FD_FRAMES, &enable, sizeof(enable));
	}

	struct sockaddr_can addr;
	memset(&addr, 0, sizeof(addr));
	addr.can_family = AF_CAN;
	addr.can_ifindex = ifr.ifr_ifindex;
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(s); return -1; }

	/* Non-blocking so the Loom scheduler is never stalled waiting on a frame. */
	int fl = fcntl(s, F_GETFL, 0);
	fcntl(s, F_SETFL, fl | O_NONBLOCK);
	return s;
}

int blob_can_send(int sock, uint32_t id, const uint8_t *data, uint8_t len, int fd_mode) {
	if (fd_mode) {
		if (len > 64) return -1;
		struct canfd_frame f;
		memset(&f, 0, sizeof(f));
		f.can_id = id;
		f.len = len;
		memcpy(f.data, data, len);
		ssize_t n = write(sock, &f, sizeof(f));
		return n == (ssize_t)sizeof(f) ? 0 : -1;
	}
	/* classic CAN: a struct can_frame (8 data bytes), so it interoperates with
	 * classic-only tools/peers. */
	if (len > 8) return -1;
	struct can_frame f;
	memset(&f, 0, sizeof(f));
	f.can_id = id;
	f.can_dlc = len;
	memcpy(f.data, data, len);
	ssize_t n = write(sock, &f, sizeof(f));
	return n == (ssize_t)sizeof(f) ? 0 : -1;
}

/* The socket is non-blocking (O_NONBLOCK), so write() can fail with EAGAIN when the
 * SocketCAN Tx queue/interface isn't writable. Report real writability via a zero-timeout
 * POLLOUT poll so the burst sender (ISO-TP dump) gates correctly instead of dropping. */
int blob_can_tx_ready(int sock) {
	if (sock < 0)
		return 0;
	struct pollfd pfd = { .fd = sock, .events = POLLOUT, .revents = 0 };
	int r = poll(&pfd, 1, 0);
	return (r > 0 && (pfd.revents & POLLOUT)) ? 1 : 0;
}

int blob_can_recv(int sock, uint32_t *id, uint8_t *data, uint8_t *len) {
	/* canfd_frame buffer receives BOTH classic (16B) and FD (72B) frames:
	 * can_id @0, len/can_dlc @4, data @8 in both layouts. */
	struct canfd_frame f;
	ssize_t n = read(sock, &f, sizeof(f));
	if (n <= 0) return -1;
	*id = f.can_id & CAN_EFF_MASK;
	*len = f.len;
	memcpy(data, f.data, f.len);
	return 0;
}

/* SocketCAN buffers received frames deeply in the kernel and, on vcan, does not drop
 * under the loads the host/sim exercises. Per-socket overrun IS observable via
 * SO_RXQ_OVFL (a cumulative drop count delivered as an SCM_RXQ_OVFL cmsg on recvmsg);
 * wiring that in would mean switching recv() off read(). Until then report 0 — the
 * receive-with-loss surfacing (REQ-CAN-DRV-008) is exercised on the FDCAN target. */
uint32_t blob_can_rx_overruns(int sock) {
	(void)sock;
	return 0u;
}

void blob_can_close(int sock) { close(sock); }
