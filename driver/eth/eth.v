module eth

// UDP datagram port for the eth bus (docs/someip.md) — one narrow contract,
// host POSIX backend in eth_udp.c; the NetX target backend arrives with the
// H735 rung. Tx (P1 events) + nonblocking rx (P2).
// No heap: datagrams are caller-owned fixed buffers.

#flag -I @VMODROOT/driver/eth
#flag @VMODROOT/driver/eth/eth_udp.c

fn C.blob_eth_open(&char, u16) int
fn C.blob_eth_send(int, &u8, u16, &u8, int) int
fn C.blob_eth_recv(int, &u8, &u16, &u8, int) int
fn C.blob_eth_close(int)

pub struct Socket {
mut:
	fd int = -1
}

// open binds the node's own static endpoint (bind_ip:port — [bus].interface +
// [someip].port). Returns false on failure.
pub fn (mut s Socket) open(bind_ip string, port u16) bool {
	s.fd = C.blob_eth_open(&char(bind_ip.str), port)
	return s.fd >= 0
}

// send ships one datagram to ip:port. Non-blocking: false = not handed to the
// stack (full buffer or error) — the caller's TxState rolls back and retries.
pub fn (s Socket) send(ip [4]u8, port u16, data &u8, len int) bool {
	return C.blob_eth_send(s.fd, &ip[0], port, data, len) == 0
}

// recv drains one datagram, nonblocking: returns the REAL datagram length
// (may exceed max — only max bytes were copied, and the caller must drop such
// a truncated datagram), with the source endpoint filled (the caller's
// static-peer filter, REQ-NET-017). -1 = none pending; 0 is a real EMPTY
// datagram (a counted short drop for the caller, not an idle socket).
pub fn (s Socket) recv(mut ip [4]u8, port &u16, buf &u8, max int) int {
	return C.blob_eth_recv(s.fd, &ip[0], port, buf, max)
}

pub fn (mut s Socket) close() {
	C.blob_eth_close(s.fd)
	s.fd = -1
}
