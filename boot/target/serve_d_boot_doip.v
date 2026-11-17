module main

import boot
import boot.bufs
import comm.doip
import driver.doipnet

// The serve loop of a [doip] node (boot/boot.mk builds it with -d boot_doip): the programming
// session over DoIP as well as the bus. The stay path enters ThreadX (boards/common/boot_net.c) and
// runs the application's own network seam — NetX through driver/eth/netx_up.c, the DoIP entity
// through driver/eth/doip_netx.c (ARP gleaning included) and driver/doipnet's loop — as the SAME
// entity the application is. A DoIP request reaches boot.Prog across doip_netx.c's mailbox, which
// this loop answers as the application's comm thread does (doipnet.serve_mailbox).

fn C.boot_net_start()
fn C.boot_net_rest()
fn C.boot_doip_logical() u16
fn C.boot_doip_functional() u16
fn C.boot_doip_vin(&u8)
fn C.boot_doip_testers(&u16) int
fn C.boot_doip_act_types(&u8) int
fn C.boot_doip_announce_count() int
fn C.boot_doip_announce_ms() int
fn C.boot_doip_net_wait_ms() u32
fn C.doip_mb_init(&u8, int, &u8, int)
fn C.doip_net_ready() int

// the DoIP buffers are the block's (main.v buffers): the entity's assembly buffer, a receive chunk,
// the response stream, and the mailbox's request and answer — all sized by the node's maximum
// message length
__global (
	g_doip      doip.Server // DoIP framing on the doip thread; the server is g_prog
	g_net_ready bool        // the DoIP listener has been seen open (Prog.net_up given)
)

fn serve() {
	C.boot_net_start() // never returns: tx_application_define, then the boot thread's boot_serve
}

// boot_net_init: from tx_application_define, before any thread runs — the entity's identity and
// policy (the node's, as its application announces them) and the mailbox
@[export: 'blobly_boot_net_init']
fn boot_net_init() {
	g_doip.entity_addr = C.boot_doip_logical()
	g_doip.functional_addr = C.boot_doip_functional()
	C.boot_doip_vin(&g_doip.vin[0])
	// DID 0xF190 answers the VIN the entity announces, as the application's does
	g_prog.add_did(0xF190, &g_doip.vin[0], 17)
	g_doip.n_testers = C.boot_doip_testers(&g_doip.testers[0])
	g_doip.n_act_types = C.boot_doip_act_types(&g_doip.act_types[0])
	g_doip.serve.answer = doipnet.answer // g_prog, across the mailbox
	// a session handed off over DoIP waits this long for the listener (the node's announcements)
	g_prog.net_wait_us = u64(C.boot_doip_net_wait_ms()) * 1000
	m := C.boot_max_message()
	lay := buffers()
	g_doip.bind(region(lay.net_asm), m) // the UDS limit is the node's maximum message (REQ-CAN-TP-023)
	C.doip_mb_init(region(lay.net_req), m, region(lay.net_resp), m)
}

// boot_serve: the boot thread (boot_net.c) — ThreadX's low-level init started the DWT clock
@[export: 'blobly_boot_serve']
fn boot_serve() {
	serve_loop()
}

// doip_run: the doip thread (driver/eth/doip_netx.c) — the announcements, then one tester at a time
@[export: 'blobly_doip_run']
fn doip_run() {
	lay := buffers()
	doipnet.run(mut g_doip, C.boot_doip_announce_count(), C.boot_doip_announce_ms(), region(lay.net_in),
		region(lay.net_out))
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
// starts its S3 then), then the mailbox — in `lay`, the buffer block's layout, fixed at entry
fn net_pass(now u64, lay bufs.Layout) {
	if !g_net_ready && C.doip_net_ready() != 0 {
		g_net_ready = true
		g_prog.net_up(now)
	}
	doipnet.serve_mailbox(mut g_prog, region(lay.net_req), region(lay.net_resp))
	if doipnet.take_push_sent() {
		g_prog.push_sent() // the routine's pushed response has itself been acknowledged
	}
	// routine work a DoIP request started (an erase, a unit at a time): its next step once its own
	// preceding response has been acknowledged, the step's response pushed to the tester
	if g_prog.work_due(boot.via_net) {
		mut wr := [16]u8{}
		n := g_prog.step(now, &wr[0])
		if n > 0 {
			doipnet.push_resp(&wr[0], n)
		}
	}
}

fn net_drain() {
	doipnet.drain_tx(now_us)
}

// rest: up to a tick for the network threads (the serve loop is above them), woken at once by a
// request posted to the mailbox
fn rest() {
	C.boot_net_rest()
}
