#include "can_socket.h"
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
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

int blob_can_send(int sock, uint32_t id, const uint8_t *data, uint8_t len) {
	if (len > 64) return -1;
	struct canfd_frame f;
	memset(&f, 0, sizeof(f));
	f.can_id = id;
	f.len = len;
	memcpy(f.data, data, len);
	ssize_t n = write(sock, &f, sizeof(f));
	return n == (ssize_t)sizeof(f) ? 0 : -1;
}

int blob_can_recv(int sock, uint32_t *id, uint8_t *data, uint8_t *len) {
	/* canfd_frame buffer also receives classic frames: can_id @0, len @4, data @8. */
	struct canfd_frame f;
	ssize_t n = read(sock, &f, sizeof(f));
	if (n <= 0) return -1;
	*id = f.can_id & CAN_EFF_MASK;
	*len = f.len;
	memcpy(data, f.data, f.len);
	return 0;
}

void blob_can_close(int sock) { close(sock); }
