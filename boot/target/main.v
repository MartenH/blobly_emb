module main

// The boot manager image (docs/bootloader.md) — ONE source for every board and every node. Bare
// metal, no kernel on the decision: decide, and either jump (happy path, from near-reset state —
// clocks and buses never touched) or stay and serve the UDS programming session (boot.Prog). Nothing
// here names a board or a node: the flash layout and the cells are the board's (bootmap.h), the
// bus, the ids and the keys the node's (gen/boot_gen.h, written by loom2v from its [boot] + [isotp]
// and [doip]), both read through boards/common/boot_glue.c. So a tester addresses the application
// and then its bootloader identically — same bus, same ids, same frame format; same DoIP entity.
// Where it serves: on a node with no DoIP the bus is the one transport and the stay path is a bare
// superloop (serve_notd_boot_doip.v); on a [doip] node the stay path enters ThreadX so the
// application's network seam serves DoIP beside the bus (serve_d_boot_doip.v, boards/common/boot_net.c).
// Built per node by boot/boot.mk (`make boot`), which a [boot] node's gen/loom_build.mk includes.
import boot
import comm.diag
import comm.isotp
import driver.can

fn C.board_clock_init()
fn C.boot_park_satellite()
fn C.board_can_clock_pins_init() // the FDCAN kernel clock + pin AF: blob_can_open does NOT mux pins
fn C.board_now_us() u64
fn C.boot_take_request(handoff &u32) u32
fn C.boot_info_normal()
fn C.boot_info_programmed()
fn C.boot_info_no_app()
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

fn now_us() u64 {
	return C.board_now_us()
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
	// the decision's facts the serve loop needs: entered by request, over a valid app, and — for a
	// handoff — the transport holding the session it opens (boot.via_*; 0 = none)
	g_requested bool
	g_app_ok    bool
	g_handoff   u32
)

fn main() {
	app_base := C.boot_app_base()
	app_size := C.boot_app_size()
	// a dual-core part's satellite release is retracted FIRST, on every path: a reset between a
	// release and its take leaves it set, and neither the app's clock init nor this boot's may
	// run with the satellite free to start
	C.boot_park_satellite()
	// --- the boot decision, from near-reset state (REQ-BOOT-001/002/010) ---
	g_requested = C.boot_take_request(&g_handoff) != 0
	// slot-bounded: a bit-rotted/torn header can keep the valid mark while its length field
	// points past the app region — check_image_slot rejects that before crc32 walks off flash
	g_app_ok = boot.check_image_slot(unsafe { &u8(app_base) }, app_size) // memory-mapped flash
	if boot.decide(g_requested, g_app_ok) == .run_app {
		C.boot_info_normal()
		C.boot_jump_app() // never returns; nothing was initialized
	}

	// --- stay: programming mode (REQ-BOOT-004: always reachable) ---
	C.boot_info_no_app()
	C.board_clock_init()
	if C.boot_can_idx() >= 0 {
		C.board_can_clock_pins_init()
	}
	g_prog.flash = boot.FlashOps{
		erase:   fl_erase
		program: fl_program
		read:    fl_read
	}
	// EXPLICIT init: field defaults are _vinit work — freestanding never runs it
	g_prog.init() // default session
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
	// valid installed image's sw_version at boot (0 when there is none) — the DID the application
	// answers too
	bl := [u8(0x00), 0x02]!
	g_prog.add_did(0xF180, &bl[0], 2)
	state := [u8(if g_app_ok { 1 } else { 0 })]!
	g_prog.add_did(0xF181, &state[0], 1)
	hdr := boot.parse_header(unsafe { &u8(app_base) })
	ver := if g_app_ok { hdr.sw_version } else { u32(0) } // a version that cannot run is no version
	vb := [u8(ver >> 24), u8(ver >> 16), u8(ver >> 8), u8(ver)]!
	g_prog.add_did(0xF195, &vb[0], 4)
	serve() // never returns: the serve loop, on its transports (the serve_*_boot_doip.v variant)
}

// serve_loop runs the programming session until a reset: on the node's diagnostic bus — opened as
// the application opens it, an FD bus in FD mode so the answers carry the application's frame
// format — and, on a [doip] node, over DoIP (net_pass). Its frame holds the channel for good: on a
// [doip] node it is the boot thread's.
fn serve_loop() {
	mut ch := can.Channel{}
	idx := C.boot_can_idx() // -1: a node with no bus (DoIP only)
	ifname := if idx == 1 { '1' } else if idx == 2 { '2' } else { '0' } // the driver's one-digit index
	can_ok := idx >= 0 && ch.open(ifname, C.boot_can_fd() != 0)
	if !can_ok && !net_serves() {
		for {} // no transport, nothing to serve — parked, but flashable over SWD
	}
	rx_id := C.boot_rx_id()
	tx_id := C.boot_tx_id()
	boot_t0 := C.board_now_us() // REQ-BOOT-014: the stay-window baseline
	if g_handoff != 0 {
		// the application answered 0x10 02 already: the tester holds a programming session, and
		// this server opens it rather than make it ask twice (the session survives the handoff),
		// held by the transport it was asked over
		g_prog.open_handed_off(boot_t0, u8(g_handoff))
	}
	for {
		now := C.board_now_us()
		net_pass(now) // the network's reports and its request, if this node serves DoIP
		// the bus side is comm/diag's, the application's own: intake, the busy guard, the answer
		// pumped with a refusal aborting it, S3 held while an exchange is in flight
		mut due := false
		if can_ok {
			due = diag.serve_step(mut g_prog, mut g_link, rx_id, tx_id, now, mut ch, &g_req[0],
				&g_rsp[0])
		} else {
			g_prog.tick(now)
			due = g_prog.reset_due()
		}
		if due {
			if can_ok {
				diag.wire_drain(mut ch, now_us) // REQ-BOOT-012: the answer on the wire, bounded
			}
			net_drain() // ... and out of TCP's transmit queue, bounded
			C.boot_info_programmed()
			C.boot_sys_reset()
		}
		// REQ-BOOT-014: entered by request over a VALID app + tester silence -> back to the app
		if g_requested && g_app_ok && g_prog.idle_return_due(now, boot_t0) {
			C.boot_info_normal()
			C.boot_sys_reset() // no request pending -> the boot jumps to the app
		}
		if !diag.in_flight(&g_link) {
			rest() // nothing in flight on the bus: give the rest of the image its turn
		}
	}
}
