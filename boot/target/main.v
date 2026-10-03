module main

// The boot manager image (docs/bootloader.md) — ONE source for every board and every node. Bare
// metal, no kernel, one superloop: decide, and either jump (happy path, from near-reset state —
// clocks and CAN never touched) or stay and serve the UDS programming session (boot.Prog) over
// ISO-TP. Nothing here names a board or a node: the flash layout and the cells are the board's
// (bootmap.h), the bus, the ids and the keys the node's (gen/boot_gen.h, written by loom2v from
// its [boot] + [isotp]), both read through boards/common/boot_glue.c. So a tester addresses the
// application and then its bootloader identically — same bus, same ids, same frame format.
// Built per node by boot/boot.mk (`make boot`), which a [boot] node's gen/loom_build.mk includes.
import boot
import comm.isotp
import driver.can

fn C.board_clock_init()
fn C.board_timebase_init()
fn C.board_can_clock_pins_init() // the FDCAN kernel clock + pin AF: blob_can_open does NOT mux pins
fn C.board_now_us() u64
fn C.boot_take_request(handoff &u32) u32
fn C.boot_set_info(reason u32)
fn C.boot_jump_app()
fn C.boot_sys_reset()
fn C.boot_app_base() u32
fn C.boot_app_size() u32
fn C.boot_rx_id() u32
fn C.boot_tx_id() u32
fn C.boot_can_idx() int
fn C.boot_can_fd() int
fn C.boot_bs() u8
fn C.boot_stmin() u8
fn C.boot_keys(image &u8, session &u8)
fn C.boot_rng(out &u8, n int) int
fn C.bflash_erase(addr u32, size u32) int
fn C.bflash_program(addr u32, data &u8, len u32) int
fn C.bflash_read(addr u32, out &u8, len u32) int

// boot_info reasons (bootmap.h BOOT_REASON_*)
const reason_normal = u32(0)
const reason_programmed = u32(1)
const reason_no_app = u32(2)

// FlashOps wrappers (the ctx is unused on target — the flash is the flash)
fn fl_erase(ctx voidptr, addr u32, size u32) bool {
	return C.bflash_erase(addr, size) != 0
}

fn fl_program(ctx voidptr, addr u32, data &u8, len u32) bool {
	return C.bflash_program(addr, data, len) != 0
}

fn fl_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	return C.bflash_read(addr, out, len) != 0
}

fn rng_hook(out &u8, n int) bool {
	return C.boot_rng(out, n) != 0
}

// module-sized state stays OUT of entry frames (stack-copy discipline)
__global (
	g_prog boot.Prog
	g_link isotp.Link
	g_req  [isotp.max_payload]u8
	g_rsp  [isotp.max_payload]u8
)

fn main() {
	app_base := C.boot_app_base()
	app_size := C.boot_app_size()
	// --- the boot decision, from near-reset state (REQ-BOOT-001/002/010) ---
	mut handoff := u32(0)
	requested := C.boot_take_request(&handoff) != 0
	// slot-bounded: a bit-rotted/torn header can keep the valid mark while its length field
	// points past the app region — check_image_slot rejects that before crc32 walks off flash
	app_ok := boot.check_image_slot(unsafe { &u8(app_base) }, app_size) // memory-mapped flash
	if boot.decide(requested, app_ok) == .run_app {
		C.boot_set_info(reason_normal)
		C.boot_jump_app() // never returns; nothing was initialized
	}

	// --- stay: programming mode (REQ-BOOT-004: always reachable) ---
	C.boot_set_info(reason_no_app)
	C.board_clock_init()
	C.board_timebase_init() // board_now_us reads DWT: without it `now` is frozen and nothing expires
	boot_t0 := C.board_now_us() // REQ-BOOT-014: the stay-window baseline
	C.board_can_clock_pins_init()
	req_id := C.boot_rx_id()
	rsp_id := C.boot_tx_id()
	mut ch := can.Channel{}
	// the node's diagnostic bus, opened as the application opens it (an FD bus in FD mode, so
	// the answers carry the frame format the application's do)
	idx := C.boot_can_idx()
	ifname := if idx == 1 { '1' } else if idx == 2 { '2' } else { '0' } // the driver's one-digit index
	if !ch.open(ifname, C.boot_can_fd() != 0) {
		for {} // no bus, nothing to serve — parked, but flashable over SWD
	}

	g_prog.flash = boot.FlashOps{
		erase:   fl_erase
		program: fl_program
		read:    fl_read
	}
	// EXPLICIT init: field defaults are _vinit work — freestanding never runs it
	g_prog.init() // default session
	if handoff != 0 {
		// the application answered 0x10 02 already: the tester holds a programming session, and
		// this server opens it rather than make it ask twice (the session survives the handoff)
		g_prog.open_handed_off(boot_t0)
	}
	// two trust anchors — image vs session, different custody (examples/keys/README.md); the
	// node's own, from its [boot]
	C.boot_keys(&g_prog.image_key[0], &g_prog.session_key[0])
	g_prog.rng = rng_hook // the 0x29 challenge source (the board's TRNG)
	g_link.init_defaults() // ISO-TP N_Bs/WFTmax — 0 would wait forever on a lost FC
	g_link.bs = C.boot_bs() // the flow control the node's [isotp] grants
	g_link.stmin = C.boot_stmin()
	g_prog.app_base = app_base
	g_prog.app_size = app_size
	// identification (REQ-BOOT-009): F180 = bootloader version, F181 = app state, F195 = the
	// installed image's sw_version — the DID the application answers too
	g_prog.srv.dids[0].id = 0xF180
	g_prog.srv.dids[0].data[0] = 0x00
	g_prog.srv.dids[0].data[1] = 0x02
	g_prog.srv.dids[0].len = 2
	g_prog.srv.dids[1].id = 0xF181
	g_prog.srv.dids[1].data[0] = if app_ok { u8(1) } else { 0 }
	g_prog.srv.dids[1].len = 1
	hdr := boot.parse_header(unsafe { &u8(app_base) })
	ver := if hdr.magic == boot.magic { hdr.sw_version } else { u32(0) }
	g_prog.srv.dids[2].id = 0xF195
	g_prog.srv.dids[2].data[0] = u8(ver >> 24)
	g_prog.srv.dids[2].data[1] = u8(ver >> 16)
	g_prog.srv.dids[2].data[2] = u8(ver >> 8)
	g_prog.srv.dids[2].data[3] = u8(ver)
	g_prog.srv.dids[2].len = 4
	g_prog.srv.ndid = 3

	for {
		now := C.board_now_us()
		mut f := can.Frame{}
		for ch.recv(mut f) {
			if f.id != req_id || f.ext || f.len < 1 {
				continue // the physical diagnostic request only
			}
			mut pdu := isotp.Pdu{}
			n := if f.len > 8 { 8 } else { int(f.len) } // classic-sized ISO-TP, on FD too
			for i in 0 .. n {
				pdu.data[i] = f.data[i]
			}
			g_link.on_frame(now, pdu)
		}
		if g_link.ready {
			n := g_link.take(&g_req[0])
			g_prog.last_rx_us = now // the tester-silence clock (REQ-BOOT-013/014)
			rn := g_prog.handle(&g_req[0], n, &g_rsp[0])
			if rn > 0 {
				g_link.send(&g_rsp[0], rn)
			}
		}
		g_prog.tick(now) // S3: a silent tester loses the session + the unlock
		// REQ-BOOT-014: entered by request over a VALID app + tester silence -> back to the app
		if requested && app_ok && g_prog.idle_return_due(now, boot_t0) {
			C.boot_set_info(reason_normal)
			C.boot_sys_reset() // no request pending -> the boot jumps to the app
		}
		g_link.tick(now)
		mut out := isotp.Pdu{}
		for ch.tx_ready() && g_link.poll(now, mut out) {
			mut tf := can.Frame{
				id:  rsp_id
				len: 8
			}
			for i in 0 .. 8 {
				tf.data[i] = out.data[i]
			}
			ch.send(tf)
			out = isotp.Pdu{}
		}
		if g_prog.reset_pending && !g_link.busy() {
			// REQ-BOOT-012: the link going idle only means the answer reached the Tx FIFO — wait
			// for the CONTROLLER to put it on the wire, bounded so a dead bus cannot hold it off
			t0 := C.board_now_us()
			for !ch.tx_idle() && C.board_now_us() - t0 < 20000 {}
			C.boot_set_info(reason_programmed)
			C.boot_sys_reset()
		}
	}
}
