module doipnet

import comm.diagroute
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
fn C.doip_mb_push_get(&u8, int) int
fn C.doip_mb_push_resp(&u8, int) int
fn C.doip_mb_take_push_sent() int
fn C.doip_mb_push_queued()
fn C.doip_mb_take(&int) int
fn C.doip_mb_answer(int)
fn C.doip_mb_take_sent() int
fn C.doip_mb_take_dropped() int
fn C.doip_tx_pending() int
fn C._tx_thread_sleep(u32) u32
fn C._tx_time_get() u32
fn C.doip_rt_call(int, &u8, int, u32, u32) int
fn C.doip_rt_take(&int, &u32, &u32) int
fn C.doip_rt_answer(int)
fn C.doip_rt_put(u16, u32, &u8, int) int
fn C.doip_rt_get(&u16, &u32) int
fn C.doip_rt_done()
fn C.doip_mb_drop_is_pending() int
fn C.doip_rt_take_ended() int

// how long one receive waits before the loop comes round again, ThreadX ticks — one tick while a
// routed node's answer is due, so it leaves within a tick of arriving rather than with the next
// tester message (a reprogramming is hundreds of request-answer turns)
const recv_ticks = u32(100)
const recv_ticks_routed = u32(1)
// ... but no longer than this many ticks without an answer (7 s: the router's own answer wait and
// then some) — an answer that never comes must not keep the loop polling at 1 kHz. Measured in
// ticks, not turns: a turn with tester traffic waiting takes no tick at all.
const routed_poll_ticks = u32(7000)

// Netx is the stream of the one TCP_DATA socket doip_netx.c serves.
pub struct Netx {
mut:
	wait u32
}

pub fn (n Netx) recv(buf &u8, max int) int {
	return C.doip_stream_recv(buf, max, if n.wait != 0 { n.wait } else { recv_ticks })
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
	run_gateway(mut s, count, interval_ms, inb, out, unsafe { nil })
}

// run_gateway is run for a gateway (REQ-NET-019): the answers of the nodes behind it come out of
// doip_netx.c's route channel into `ans` (doip.max_uds bytes, registered with doip_rt_init) and go
// to the tester as diagnostic messages from those nodes. ans = nil: a node that routes nothing.
pub fn run_gateway(mut s doip.Server, count int, interval_ms int, inb &u8, out &u8, ans &u8) {
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
	mut pushed := [16]u8{}
	mut fast_since := u32(0)
	mut fast_ticket := s.ticket
	for {
		// a response the server pushed (a routine's next one) goes out first
		n := C.doip_mb_push_get(&pushed[0], pushed.len)
		if n >= 0 && push(mut st, mut s, &pushed[0], n, out) {
			C.doip_mb_push_queued()
		}
		if ans != unsafe { nil } {
			mut from := u16(0)
			mut ticket := u32(0)
			an := C.doip_rt_get(&from, &ticket)
			if an >= 0 {
				if routed(mut st, mut s, from, ticket, ans, an, out) {
					fast_since = C._tx_time_get() // an answer (a responsePending): the next is due anew
				}
				C.doip_rt_done()
			}
		}
		if s.ticket != fast_ticket {
			fast_ticket = s.ticket // a new routed request: its own fast-poll budget
			fast_since = C._tx_time_get()
		}
		if s.route_open && C._tx_time_get() - fast_since > routed_poll_ticks {
			s.route_open = false // given up on: the tester's own P2* has long told it
		}
		st.wait = if s.route_open { recv_ticks_routed } else { recv_ticks }
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

// route is comm/doip's Serve hook to the router on the comm thread (a gateway): the request goes
// across doip_netx.c's route channel, the router's verdict comes back — 0 forwarded, else the NACK
// code; not taken in time, a transport error (it was never forwarded).
pub fn route(ctx voidptr, idx int, req &u8, n int, conn u32, ticket u32) int {
	code := C.doip_rt_call(idx, req, n, conn, ticket)
	return if code < 0 { int(doip.dnack_transport_error) } else { code }
}

// serve_routes is the comm thread's share of a gateway's pass, after serve_mailbox: the security
// level the network tester holds on the gateway's own server now, which the router keeps for the
// connection once it is the route level (hold: every pass, so an unlock outlives S3 before the
// first routed request too), and the routed request waiting, judged by the router — but neither
// while a dropped connection is still untaken (serve_mailbox takes it next pass and ends that
// tester's unlock first: a new tester never routes on it, REQ-NET-020); then the answers the
// router has, into the channel while it has room. req holds doip.max_uds bytes (registered with
// doip_rt_init).
pub fn serve_routes(mut r diagroute.Router, unlocked u8, req &u8, now u64) {
	if C.doip_rt_take_ended() != 0 {
		r.cancel() // the tester went: its exchange and answers are no one's
	}
	mut idx := 0
	mut conn := u32(0)
	mut ticket := u32(0)
	if C.doip_mb_drop_is_pending() == 0 {
		r.hold(unlocked)
		n := C.doip_rt_take(&idx, &conn, &ticket)
		if n >= 0 {
			C.doip_rt_answer(verdict_code(r.accept(idx, req, n, conn, ticket, unlocked, now)))
		}
	}
	for r.waiting() > 0 {
		a := r.head()
		if C.doip_rt_put(a.logical, a.ticket, &a.data[0], a.len) == 0 {
			break
		}
		r.pop()
	}
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

// push_resp: the server thread pushes a further response to the request it served last (in flight
// until acknowledged, doip_mb.h); false when it does not fit the mailbox's push buffer
pub fn push_resp(resp &u8, n int) bool {
	return C.doip_mb_push_resp(resp, n) != 0
}

// take_push_sent: the response pushed last has itself been acknowledged (reported once)
pub fn take_push_sent() bool {
	return C.doip_mb_take_push_sent() != 0
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
