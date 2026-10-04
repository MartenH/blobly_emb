module main

import comm.doip
import driver.doipnet

// The serve loop of a [doip] node (boot/boot.mk builds it with -d boot_doip): the programming
// session over DoIP as well as the bus. The stay path enters ThreadX (boards/common/boot_net.c) and
// runs the application's own network seam — NetX through driver/eth/netx_up.c, the DoIP entity
// through driver/eth/doip_netx.c (ARP gleaning included) and driver/doipnet's loop — as the SAME
// entity the application is. A DoIP request reaches boot.Prog across doip_netx.c's mailbox, which
// this loop answers on every pass, as the application's comm thread does.

fn C.boot_net_start()
fn C.boot_doip_logical() u16
fn C.boot_doip_functional() u16
fn C.boot_doip_vin(&u8)
fn C.boot_doip_testers(&u16) int
fn C.boot_doip_act_types(&u8) int
fn C.boot_doip_announce_count() int
fn C.boot_doip_announce_ms() int
fn C.doip_mb_init(&u8, &u8)
fn C.doip_mb_take(&int) int
fn C.doip_mb_answer(int)
fn C.doip_mb_take_sent() int
fn C.doip_mb_take_dropped() int
fn C.doip_tx_pending() int
fn C.doip_net_ready() int

// how long a reset waits for the answers already handed to TCP to be acknowledged (the
// application's comm thread waits as long)
const tcp_drain_us = u64(500_000)

__global (
	g_doip      doip.Server // DoIP framing on the doip thread; the server is g_prog
	g_doip_in   [doip.max_msg]u8
	g_doip_out  [doip.max_resp]u8
	g_doip_req  [doip.max_msg]u8 // the mailbox: a request on its way to the serve loop
	g_doip_resp [doip.max_uds]u8 // ... and its answer on the way back
	g_net_ready bool            // the DoIP listener has been seen open (Prog.net_up given)
)

fn serve() {
	// the entity's identity and policy: the node's, as its application announces them
	g_doip.entity_addr = C.boot_doip_logical()
	g_doip.functional_addr = C.boot_doip_functional()
	C.boot_doip_vin(&g_doip.vin[0])
	g_doip.n_testers = C.boot_doip_testers(&g_doip.testers[0])
	g_doip.n_act_types = C.boot_doip_act_types(&g_doip.act_types[0])
	g_doip.serve.answer = doipnet.answer // g_prog, across the mailbox
	C.doip_mb_init(&g_doip_req[0], &g_doip_resp[0])
	C.boot_net_start() // never returns: the boot thread runs blobly_boot_serve
}

// boot_serve: the boot thread (boot_net.c) — ThreadX's low-level init started the DWT clock
@[export: 'blobly_boot_serve']
fn boot_serve() {
	serve_loop()
}

// doip_run: the doip thread (driver/eth/doip_netx.c) — the announcements, then one tester at a time
@[export: 'blobly_doip_run']
fn doip_run() {
	doipnet.run(mut g_doip, C.boot_doip_announce_count(), C.boot_doip_announce_ms(), &g_doip_in[0],
		&g_doip_out[0])
}

// doip_udp: a request on UDP 13400 (the doip-svc thread) — identification, entity status, power mode
@[export: 'blobly_doip_udp']
fn doip_udp(req &u8, n int, resp &u8) int {
	return doipnet.udp(&g_doip, req, n, resp)
}

fn net_serves() bool {
	return true
}

// net_pass: the network's share of a pass — the listener coming up (a session handed off over DoIP
// starts its S3 then), what the doip thread reported (an answer sent: a reset waiting on it may go;
// a connection dropped: what it held ends), then a request waiting in the mailbox
fn net_pass(now u64) {
	if !g_net_ready && C.doip_net_ready() != 0 {
		g_net_ready = true
		g_prog.net_up(now)
	}
	if C.doip_mb_take_sent() != 0 {
		g_prog.remote_sent()
	}
	if C.doip_mb_take_dropped() != 0 {
		g_prog.remote_dropped()
	}
	mut functional := 0
	n := C.doip_mb_take(&functional)
	if n >= 0 {
		C.doip_mb_answer(g_prog.serve_remote(&g_doip_req[0], n, functional != 0, &g_doip_resp[0],
			now))
	}
}

// net_drain: before a reset, the DoIP answers already handed to TCP leave it — bounded, as the bus
// drain is (a peer that never acknowledges gets the reset all the same)
fn net_drain() {
	t0 := C.board_now_us()
	for C.doip_tx_pending() != 0 && C.board_now_us() - t0 < tcp_drain_us {}
}
