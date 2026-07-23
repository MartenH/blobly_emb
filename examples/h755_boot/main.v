module main

// h755_boot — the boot manager (docs/bootloader.md), bank-1 sector 0. Bare
// metal, no kernel, one superloop: decide, and either jump (happy path, from
// near-reset state — clocks and CAN never touched) or stay and serve the UDS
// programming session over ISO-TP (rx 0x7B0 / tx 0x7B8), exactly the session
// examples/boot_sim proved on vcan — same boot.Prog, different FlashOps.
//
// *** TARGET SKELETON: compiles freestanding; flash.c is dry-coded and the
// whole image is BENCH-UNVERIFIED (P1/P2 hardware pass pending). ***
import boot
import comm.isotp
import driver.can

// boards/h755zi/bootmap.h owns these numbers — keep in lockstep (the V side
// cannot include the C header; ecucheck-style codegen can bind them later).
const app_base = u32(0x0802_0000)
const app_size = u32(0x000E_0000)
const req_id = u32(0x7B0)
const rsp_id = u32(0x7B8)

fn C.board_clock_init()
fn C.board_timebase_init()
fn C.board_can_clock_pins_init() // FDCAN1 kernel clock + PD0/PD1 AF9 — blob_can_open does NOT mux pins
fn C.board_now_us() u64
fn C.board_rng(out &u8, n int) int
fn C.bootcell_take_request() u32
fn C.bootcell_set_info(reason u32)
fn C.boot_jump_app()
fn C.boot_sys_reset()
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

// module-sized state stays OUT of entry frames (stack-copy discipline)
__global (
	g_prog boot.Prog
	g_link isotp.Link
	g_req  [isotp.max_payload]u8 // derived from the cap — a hard-coded 520 here is an overflow if the cap is ever raised (codex #202)
	g_rsp  [isotp.max_payload]u8
)

fn rng_hook(out &u8, n int) bool {
	return C.board_rng(out, n) != 0
}

fn main() {
	// --- the boot decision, from near-reset state (REQ-BOOT-001/002/010) ---
	requested := C.bootcell_take_request() != 0
	// slot-bounded: a bit-rotted/torn header can keep the valid mark while its
	// length field points past the app region — check_image_slot rejects that
	// before crc32 walks off the end of flash (fault before CAN is up)
	app_ok := boot.check_image_slot(unsafe { &u8(app_base) }, app_size) // memory-mapped flash
	if boot.decide(requested, app_ok) == .run_app {
		C.bootcell_set_info(0) // BOOT_REASON_NORMAL
		C.boot_jump_app() // never returns; nothing was initialized
	}

	// --- stay: programming mode (REQ-BOOT-004: always reachable) ---
	C.bootcell_set_info(2) // BOOT_REASON_NO_APP (or a pending request)
	C.board_clock_init()
	C.board_timebase_init() // board_now_us reads DWT: without this, `now` is frozen
	// at 0 — the ISO-TP timeouts AND the REQ-BOOT-012 reset bound would never
	// expire (codex on emb#132: an unbounded wait on a dead bus)
	boot_t0 := C.board_now_us() // REQ-BOOT-014: the stay-window baseline
	C.board_can_clock_pins_init() // found on the P2 bench: without the pin mux the session times out
	mut ch := can.Channel{}
	if !ch.open('0', false) {
		for {} // no bus, nothing to serve — parked, but flashable over SWD
	}

	g_prog.flash = boot.FlashOps{
		erase:   fl_erase
		program: fl_program
		read:    fl_read
	}
	// EXPLICIT init: field defaults are _vinit work — freestanding never runs it
	// (the P2 bench found seed reading 0 = the already-unlocked convention).
	g_prog.init() // seed + default session
	// dev image-signing public key (examples/keys) — REAL deployments bake their
	// own; the matching seed never touches an ECU or build machine (REQ-BOOT-011)
	// two trust anchors (examples/keys) — image vs session, different custody
	g_prog.image_key = [u8(0x03), 0xa1, 0x07, 0xbf, 0xf3, 0xce, 0x10, 0xbe, 0x1d, 0x70, 0xdd, 0x18, 0xe7, 0x4b, 0xc0, 0x99, 0x67, 0xe4, 0xd6, 0x30, 0x9b, 0xa5, 0x0d, 0x5f, 0x1d, 0xdc, 0x86, 0x64, 0x12, 0x55, 0x31, 0xb8]!
	g_prog.session_key = [u8(0x29), 0xac, 0xba, 0xe1, 0x41, 0xbc, 0xca, 0xf0, 0xb2, 0x2e, 0x1a, 0x94, 0xd3, 0x4d, 0x0b, 0xc7, 0x36, 0x1e, 0x52, 0x6d, 0x0b, 0xfe, 0x12, 0xc8, 0x97, 0x94, 0xbc, 0x93, 0x22, 0x96, 0x6d, 0xd7]!
	g_prog.rng = rng_hook // 0x29 challenge source (STM32H7 TRNG)
	g_link.init_defaults() // ISO-TP N_Bs/WFTmax — 0 would wait forever on a lost FC
	g_prog.app_base = app_base
	g_prog.app_size = app_size
	// identification (REQ-BOOT-009): F180 = bootloader version, F181 = app state
	g_prog.srv.dids[0].id = 0xF180
	g_prog.srv.dids[0].data[0] = 0x00
	g_prog.srv.dids[0].data[1] = 0x01
	g_prog.srv.dids[0].len = 2
	g_prog.srv.dids[1].id = 0xF181
	g_prog.srv.dids[1].data[0] = if app_ok { u8(1) } else { 0 }
	g_prog.srv.dids[1].len = 1
	g_prog.srv.ndid = 2

	for {
		now := C.board_now_us()
		mut f := can.Frame{}
		for ch.recv(mut f) {
			if f.id != req_id || f.ext {
				continue // standard-id diagnostic request only — an extended alias is not a boot request
			}
			mut pdu := isotp.Pdu{}
			for i in 0 .. 8 {
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
		// REQ-BOOT-014: entered by request over a VALID app + tester silence ->
		// give the ECU back to the application (a dead tester must not park it)
		if requested && app_ok && g_prog.idle_return_due(now, boot_t0) {
			C.bootcell_set_info(0) // BOOT_REASON_NORMAL
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
			// REQ-BOOT-012: the link going idle only means the 0x51 response
			// reached the Tx FIFO — wait for the CONTROLLER to put it on the
			// wire, bounded so a dead bus can't hold off the reset (found on
			// the P2 bench: cmd/flash saw 'ecu reset: timeout').
			t0 := C.board_now_us()
			for !ch.tx_idle() && C.board_now_us() - t0 < 20000 {}
			C.bootcell_set_info(1) // BOOT_REASON_PROGRAMMED
			C.boot_sys_reset()
		}
	}
}
