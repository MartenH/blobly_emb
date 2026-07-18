// examples/h735_doip — DoIP on the STM32H735-DK (docs/net.md P3b, REQ-NET-007):
// the FIRST V+NetX image. Every byte above the TCP/UDP stream is tested V code
// (comm.doip framing driving the same comm.uds server the bus transport uses);
// netx_glue.c owns ThreadX/NetX/sockets and exposes a four-call seam
// (stream recv/send, UDP broadcast, EID) plus the link poll.
//
// Bench: DoIP tester (blobly_net cantester, or any ISO 13400 client) to
// 192.168.0.50:13400 — routing activation, then UDS 0x22/0x3E/0x10/0x2E.
import comm.doip

fn C.board_clock_init()
fn C.glue_kernel_enter()
fn C.net_stream_recv(buf &u8, max int, timeout_ticks u32) int
fn C.net_stream_send(buf &u8, len int) int
fn C.net_udp_broadcast(port int, buf &u8, len int)
fn C.net_eid(eid &u8)
fn C.net_link_poll()

// module-sized state lives on the __global, initialized IN PLACE — never built
// by value on a thread stack (the stack-copy boot-hang rule).
__global g_srv doip.Server

@[export: 'blobly_doip_run']
fn blobly_doip_run() {
	// identity: DoIP logical address + VIN (bench values; config-generated later)
	g_srv.entity_addr = 0x0E80
	vin := 'BLOBLYH735DK00001'
	for i in 0 .. 17 {
		g_srv.vin[i] = vin[i]
	}
	// UDS: default session, one identification DID (0xF190) the bench reads
	g_srv.uds.session = 0x01
	g_srv.uds.dids[0].id = 0xF190
	name := 'H735-DK'
	for i in 0 .. name.len {
		g_srv.uds.dids[0].data[i] = name[i]
	}
	g_srv.uds.dids[0].len = u8(name.len)
	g_srv.uds.ndid = 1

	// ISO 13400 discovery: broadcast the vehicle announcement 3x at boot
	mut eid := [6]u8{}
	C.net_eid(&eid[0])
	mut abuf := [64]u8{}
	alen := g_srv.announcement(&eid[0], &abuf[0])
	for _ in 0 .. 3 {
		C.net_udp_broadcast(13400, &abuf[0], alen)
	}

	mut inb := [256]u8{}
	mut resp := [512]u8{}
	for {
		n := C.net_stream_recv(&inb[0], 256, 100) // ~100 ms slice
		if n > 0 {
			rlen := g_srv.feed(&inb[0], n, &resp[0], 512)
			if rlen > 0 {
				C.net_stream_send(&resp[0], rlen)
			}
		} else if n < 0 {
			// connection dropped: a new tester must re-activate routing
			g_srv.activated = false
			g_srv.buf_len = 0
		} else {
			C.net_link_poll() // idle: keep MACCR synced to the live link
		}
	}
}

fn main() {
	C.board_clock_init() // 550 MHz PLL1 + I-cache
	C.glue_kernel_enter() // ThreadX -> netx_glue tx_application_define; no return
}
