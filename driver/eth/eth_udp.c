// UDP datagram port — host backend (POSIX sockets on loopback/LAN), the eth
// counterpart of driver/can/can_socket.c. The SOME/IP comm thread sends its
// event datagrams through this seam; the NetX target backend replaces it at
// the H735 rung (docs/someip.md). No heap: the caller owns every buffer.
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>

// blob_eth_open binds a UDP socket to bind_ip:port (the node's own static
// endpoint — a stable source address the peer's rx filter can pin against).
// Returns the fd, or -1.
int blob_eth_open(const char *bind_ip, unsigned short port) {
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		return -1;
	}
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	if (inet_pton(AF_INET, bind_ip, &a.sin_addr) != 1) {
		close(fd);
		return -1;
	}
	if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) {
		close(fd);
		return -1;
	}
	// non-blocking: the comm thread must never park on the socket — a socket
	// that cannot be made nonblocking is a failed open, not a silent hazard
	int fl = fcntl(fd, F_GETFL, 0);
	if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

// blob_eth_send sends one datagram to ip[4]:port. 0 = handed to the stack.
int blob_eth_send(int fd, const unsigned char *ip, unsigned short port,
                  const unsigned char *buf, int len) {
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	memcpy(&a.sin_addr.s_addr, ip, 4);
	return sendto(fd, buf, (size_t)len, 0, (struct sockaddr *)&a, sizeof a) == (ssize_t)len ? 0 : -1;
}

void blob_eth_close(int fd) {
	if (fd >= 0) {
		close(fd);
	}
}

/* blob_eth_recv: one datagram, nonblocking. Returns the REAL datagram length
 * (MSG_TRUNC), which may exceed max — only max bytes were copied, and the
 * caller must DROP such a datagram rather than decode its truncated prefix
 * (an oversize datagram whose header lies consistently would otherwise pass
 * every gate). src ip/port filled for the caller's peer filter; 0 = nothing
 * pending. */
int blob_eth_recv(int fd, unsigned char *ip, unsigned short *port,
                  unsigned char *buf, int max) {
	struct sockaddr_in a;
	socklen_t alen = sizeof a;
	long n = recvfrom(fd, buf, (size_t)max, MSG_TRUNC, (struct sockaddr *)&a, &alen);
	if (n < 0) {
		return 0; /* EAGAIN/EWOULDBLOCK and friends: nothing pending */
	}
	memcpy(ip, &a.sin_addr.s_addr, 4);
	*port = ntohs(a.sin_port);
	return (int)n;
}
