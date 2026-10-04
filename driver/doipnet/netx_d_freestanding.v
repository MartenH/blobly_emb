module doipnet

import comm.doip

// The target half: doipnet's loop over driver/eth/doip_netx.c (the ThreadX + NetX seam). Only a
// freestanding image compiles this file — the C symbols exist only there.

fn C.doip_stream_recv(&u8, int, u32) int
fn C.doip_stream_send(&u8, int) int
fn C.doip_stream_drop()
fn C.doip_stream_notify_activated(int)
fn C.doip_stream_open() int
fn C.doip_udp_broadcast(&u8, int)
fn C.doip_eid(&u8)
fn C.doip_sleep_ms(int)
fn C.doip_mb_call(&u8, int, int, &u8, int) int
fn C.doip_mb_take(&int) int
fn C.doip_mb_answer(int)
fn C.doip_mb_take_sent() int
fn C.doip_mb_take_dropped() int
fn C.doip_tx_pending() int
fn C._tx_thread_sleep(u32) u32

// how long one receive waits before the loop comes round again, ThreadX ticks
const recv_ticks = u32(100)

// Netx is the stream of the one TCP_DATA socket doip_netx.c serves.
pub struct Netx {}

pub fn (n Netx) recv(buf &u8, max int) int {
	return C.doip_stream_recv(buf, max, recv_ticks)
}

pub fn (n Netx) send(buf &u8, len int) int {
	return C.doip_stream_send(buf, len)
}

pub fn (n Netx) drop() {
	C.doip_stream_drop()
}

pub fn (n Netx) activated(on bool) {
	C.doip_stream_notify_activated(if on { 1 } else { 0 })
}

// run is the doip thread's body (doip_netx.c calls the image's blobly_doip_run once its sockets
// are up): `count` vehicle announcements `interval_ms` apart (A_DoIP_Announce_Num /
// A_DoIP_Announce_Interval), then one tester at a time, forever. inb holds doip.max_msg bytes,
// out doip.max_resp.
pub fn run(mut s doip.Server, count int, interval_ms int, inb &u8, out &u8) {
	if count > 0 {
		mut eid := [6]u8{}
		C.doip_eid(&eid[0])
		mut ann := [64]u8{}
		an := s.announcement(&eid[0], &ann[0])
		for i in 0 .. count {
			if i > 0 {
				C.doip_sleep_ms(interval_ms)
			}
			C.doip_udp_broadcast(&ann[0], an)
		}
	}
	mut st := Netx{}
	for {
		pass(mut st, mut s, inb, out)
	}
}

// udp answers one datagram on UDP 13400 (the doip-svc thread): identification, entity status,
// power mode — with this entity's identity and the TCP_DATA sockets open now.
pub fn udp(s &doip.Server, req &u8, n int, resp &u8) int {
	mut eid := [6]u8{}
	C.doip_eid(&eid[0])
	return s.udp_response(req, n, &eid[0], C.doip_stream_open(), resp)
}

// answer is comm/doip's Serve hook to a diagnostic server another thread owns: the request goes
// across doip_netx.c's mailbox and the answer comes back (-1 = not served in time: NACKed).
pub fn answer(ctx voidptr, req &u8, n int, functional bool, resp &u8, cap int) int {
	return C.doip_mb_call(req, n, int(functional), resp, cap)
}

// serve_mailbox is the server thread's share of a pass — the application's comm thread
// (comm/diag.Connection) and the bootloader's serve loop (boot.Prog) alike: what the doip thread
// reported (an answer sent: a reset waiting on it may go; a connection dropped: what it held ends),
// then the request waiting in the mailbox, served and answered. The server answers remote_sent,
// remote_dropped and serve_remote(req, n, functional, resp) int. req holds doip.max_msg bytes,
// resp doip.max_uds.
pub fn serve_mailbox[T](mut s T, req &u8, resp &u8) {
	if C.doip_mb_take_sent() != 0 {
		s.remote_sent()
	}
	if C.doip_mb_take_dropped() != 0 {
		s.remote_dropped()
	}
	mut functional := 0
	n := C.doip_mb_take(&functional)
	if n >= 0 {
		C.doip_mb_answer(s.serve_remote(req, n, functional != 0, resp))
	}
}

// how long a reset waits for the answers already handed to TCP to be acknowledged
pub const tx_drain_us = u64(500_000)

// drain_tx: before the MCU resets, the DoIP answers already handed to TCP leave it — the reset's own
// answer was acknowledged before the reset became due (driver/eth/doip_mb.h); this covers any
// other still queued — bounded by
// tx_drain_us on `clock`, as the bus drain is (a peer that never acknowledges gets the reset all
// the same). Sleeps a tick a turn, so the network threads below the caller can send.
pub fn drain_tx(clock fn () u64) {
	t0 := clock()
	for C.doip_tx_pending() != 0 && clock() - t0 < tx_drain_us {
		C._tx_thread_sleep(1)
	}
}
