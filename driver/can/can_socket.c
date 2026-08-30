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

static void ovfl_reset(int fd); /* defined below (per-fd SO_RXQ_OVFL drop-count table) */

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

	/* Ask the kernel to report per-socket Rx-queue drops as SO_RXQ_OVFL ancillary data on
	 * recvmsg, so blob_can_rx_overruns() can surface receive-with-loss (REQ-CAN-DRV-008). */
#ifdef SO_RXQ_OVFL
	int ovfl_on = 1;
	setsockopt(s, SOL_SOCKET, SO_RXQ_OVFL, &ovfl_on, sizeof(ovfl_on));
#endif
	ovfl_reset(s); /* fresh session: drop any stale tally for a reused fd */

	/* Non-blocking so the Loom scheduler is never stalled waiting on a frame. */
	int fl = fcntl(s, F_GETFL, 0);
	fcntl(s, F_SETFL, fl | O_NONBLOCK);
	return s;
}

int blob_can_send(int sock, uint32_t id, const uint8_t *data, uint8_t len, int flags) {
	/* a 29-bit extended id is carried in the low bits with CAN_EFF_FLAG set. */
	uint32_t can_id = id;
	if (flags & BLOB_CAN_FLAG_EXT)
		can_id |= CAN_EFF_FLAG;
	if (flags & BLOB_CAN_FLAG_FD) {
		if (len > 64) return -1;
		struct canfd_frame f;
		memset(&f, 0, sizeof(f));
		f.can_id = can_id;
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
	f.can_id = can_id;
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

/* Host SocketCAN: the kernel queue drains asynchronously and a sim reset is not a
 * power event — idle by definition (the target semantics live in can_fdcan.c). */
int blob_can_tx_idle(int sock) {
	(void)sock;
	return 1;
}

/* Per-socket cumulative kernel Rx-queue drop count, kept from the SO_RXQ_OVFL ancillary
 * data recvmsg() delivers. Small fixed table; a slot is free when !in_use (an explicit
 * flag, not an fd sentinel — socket() can legitimately return fd 0 with stdin closed).
 * open() claims/clears a slot, close() releases it. */
#ifdef SO_RXQ_OVFL
static struct {
	int fd;
	uint32_t ovfl;
	int in_use;
} g_ovfl[16];

static void ovfl_store(int fd, uint32_t v) {
	for (int i = 0; i < 16; i++)
		if (g_ovfl[i].in_use && g_ovfl[i].fd == fd) {
			g_ovfl[i].ovfl = v;
			return;
		}
	for (int i = 0; i < 16; i++)
		if (!g_ovfl[i].in_use) {
			g_ovfl[i].in_use = 1;
			g_ovfl[i].fd = fd;
			g_ovfl[i].ovfl = v;
			return;
		}
}
#endif

/* Reset any slot for this fd (open reuse / close). */
static void ovfl_reset(int fd) {
#ifdef SO_RXQ_OVFL
	for (int i = 0; i < 16; i++)
		if (g_ovfl[i].in_use && g_ovfl[i].fd == fd) {
			g_ovfl[i].in_use = 0;
			g_ovfl[i].fd = 0;
			g_ovfl[i].ovfl = 0;
		}
#else
	(void)fd;
#endif
}

int blob_can_recv(int sock, uint32_t *id, uint8_t *data, uint8_t *len, int *flags) {
	/* canfd_frame buffer receives BOTH classic (16B) and FD (72B) frames:
	 * can_id @0, len/can_dlc @4, data @8 in both layouts. recvmsg (not read) so the
	 * SO_RXQ_OVFL ancillary data — the kernel's cumulative Rx-queue drop count — rides
	 * along and we can surface receive-with-loss (REQ-CAN-DRV-008). */
	struct canfd_frame f;
	struct iovec iov = { .iov_base = &f, .iov_len = sizeof(f) };
	/* Keep draining past REMOTE (RTR) frames within this call: Frame has no RTR flag, so
	 * returning "empty" on one would stop the bridge's drain loop and starve the data
	 * frames queued behind it. Skip RTR and read the next frame instead (the FDCAN
	 * backends drop RTR too). The socket is non-blocking, so an empty queue ends the loop. */
	for (;;) {
#ifdef SO_RXQ_OVFL
		union {
			char buf[CMSG_SPACE(sizeof(uint32_t))];
			struct cmsghdr align;
		} ctrl;
		struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl.buf,
			              .msg_controllen = sizeof(ctrl.buf) };
#else
		struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
#endif
		ssize_t n = recvmsg(sock, &msg, 0);
		if (n <= 0) return -1;
#ifdef SO_RXQ_OVFL
		for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
			if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SO_RXQ_OVFL) {
				uint32_t ovfl;
				memcpy(&ovfl, CMSG_DATA(c), sizeof(ovfl));
				ovfl_store(sock, ovfl);
			}
		}
#endif
		if (f.can_id & CAN_RTR_FLAG)
			continue; /* remote frame: skip, keep draining */
		*id = f.can_id & CAN_EFF_MASK;
		*len = f.len;
		*flags = 0;
		if (f.can_id & CAN_EFF_FLAG)
			*flags |= BLOB_CAN_FLAG_EXT;
		if (n == (ssize_t)CANFD_MTU) /* a canfd_frame (72B) was read, not a 16B can_frame */
			*flags |= BLOB_CAN_FLAG_FD;
		memcpy(data, f.data, f.len);
		return 0;
	}
}

/* Rx-overrun events: the kernel's per-socket Rx-queue drop count (SO_RXQ_OVFL). Under
 * back-pressure — the bridge draining slower than frames arrive — the kernel drops from
 * this socket's receive queue and reports the running total, which we surface here rather
 * than losing silently (REQ-CAN-DRV-008). 0 where the platform lacks SO_RXQ_OVFL. */
uint32_t blob_can_rx_overruns(int sock) {
#ifdef SO_RXQ_OVFL
	for (int i = 0; i < 16; i++)
		if (g_ovfl[i].in_use && g_ovfl[i].fd == sock)
			return g_ovfl[i].ovfl;
#endif
	(void)sock;
	return 0u;
}

uint32_t blob_can_busoff_recoveries(int sock) {
	(void)sock;
	/* SocketCAN: bus-off handling belongs to the kernel driver (ip link ... restart-ms);
	 * this backend never sees the controller, so it reports no recoveries of its own. */
	return 0u;
}

void blob_can_close(int sock) {
	ovfl_reset(sock);
	close(sock);
}
