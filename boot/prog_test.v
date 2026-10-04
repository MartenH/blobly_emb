module boot

import bcrypto
import rand

// the target's rule for when a DoIP answer counts as sent (acknowledged), driven by the model walk
#flag -I @VMODROOT/driver/eth
#include "doip_mb.h"

@[typedef]
struct C.doip_mb_t {
	served u32
}

fn C.doip_mb_post(&C.doip_mb_t) u32
fn C.doip_mb_serve(&C.doip_mb_t)
fn C.doip_mb_queue(&C.doip_mb_t)
fn C.doip_mb_drop(&C.doip_mb_t)
fn C.doip_mb_sent_take(&C.doip_mb_t, u32, u32) int
fn C.doip_mb_dropped_take(&C.doip_mb_t) int

// @verifies REQ-BOOT-005, REQ-BOOT-008, REQ-BOOT-009
// The full programming session against RAM-backed FlashOps: the same session
// logic the target and the vcan simulator run, REQ-checked at the byte level.

const t_base = u32(0x0002_0000) // "app region" base (bootloader lives below)
const t_size = u32(0x0001_0000)

struct TestFlash {
mut:
	mem        [65536]u8
	erases     int
	fail_prog  bool
	programmed u32 // bytes programmed (tail padding included)
}

fn tf_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &TestFlash(ctx) }
	for i in u32(0) .. size {
		f.mem[addr - t_base + i] = 0xFF
	}
	f.erases++
	return true
}

fn tf_program(ctx voidptr, addr u32, data &u8, len u32) bool {
	mut f := unsafe { &TestFlash(ctx) }
	if f.fail_prog {
		return false
	}
	for i in u32(0) .. len {
		f.mem[addr - t_base + i] = unsafe { data[i] }
	}
	f.programmed += len
	return true
}

fn tf_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	f := unsafe { &TestFlash(ctx) }
	for i in u32(0) .. len {
		unsafe {
			out[i] = f.mem[addr - t_base + i]
		}
	}
	return true
}

// deterministic non-zero challenge source for tests (the board's TRNG on target)
fn fake_rng(out &u8, n int) bool {
	unsafe {
		for i in 0 .. n {
			out[i] = u8((i * 7 + 1) & 0xff)
		}
	}
	return true
}

fn new_prog(mut f TestFlash) Prog {
	mut p := Prog{
		flash:    FlashOps{
			ctx:     f
			erase:   tf_erase
			program: tf_program
			read:    tf_read
		}
		app_base: t_base
		app_size: t_size
	}
	p.init()
	p.rng = fake_rng // 0x29 challenge source
	p.image_key = image_pubkey() // verifies the firmware signature
	p.session_key = tester_pubkey() // verifies the 0x29 proof
	return p
}

// ask: one request/response exchange; returns the final response bytes — a routine answered
// responsePending is stepped to its answer, as the serve loop does once each response has left.
fn ask(mut p Prog, req []u8) []u8 {
	return ask_at(mut p, req, 0)
}

// ask_at: ask, its routine steps taken at `now` (each step is tester activity)
fn ask_at(mut p Prog, req []u8, now u64) []u8 {
	mut resp := []u8{len: 600}
	mut n := p.handle(&req[0], req.len, unsafe { &resp[0] })
	mut stepped := false
	for n == 3 && resp[0] == 0x7F && resp[2] == 0x78 {
		assert !p.work_due(via_bus), 'a step before its 0x78 left'
		p.work_left() // the transport: the 0x78 is on the wire
		assert p.work_due(via_bus)
		n = p.step(now, unsafe { &resp[0] })
		stepped = true
	}
	if stepped {
		p.work_left() // ... and so is the routine's answer
	}
	return resp[..n]
}

// unlock runs the 0x29 challenge/response: request a challenge, sign it with the
// dev private key, send the proof — exactly what the host flasher does.
fn unlock(mut p Prog) {
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50 // programming session
	ch := ask(mut p, [u8(0x29), 0x01]) // requestChallenge
	assert ch[0] == 0x69 && ch[1] == 0x01 && ch.len == 34
	challenge := ch[2..34].clone()
	sig := bcrypto.sign(tester_seed, challenge)
	mut proof := [u8(0x29), 0x02]
	for i in 0 .. 64 {
		proof << sig[i]
	}
	assert ask(mut p, proof) == [u8(0x69), 0x02]
}

// build a valid (unmarked) image: header word 0 + payload, as the host flasher
// transfers it — the mark comes from the check routine, never from the wire.
fn payload_image(image_len u32) []u8 {
	mut img := []u8{len: int(hdr_size) + int(image_len)}
	for i in 0 .. int(image_len) {
		img[int(hdr_size) + i] = u8(i ^ (i >> 3))
	}
	crc := crc32(unsafe { &img[int(hdr_size)] }, image_len)
	mut hdr := [64]u8{}
	make_header(mut hdr, image_len, crc, 7, false)
	for i in 0 .. 64 {
		img[i] = hdr[i]
	}
	return img
}

fn transfer(mut p Prog, img []u8) {
	// erase whole app window
	mut er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), u8(t_size >> 24), u8(t_size >> 16), u8(t_size >> 8), u8(t_size)]
	assert ask(mut p, er) == [u8(0x71), 0x01, 0xFF, 0x00, 0x00]
	// request download for the image extent
	sz := u32(img.len)
	dl := [u8(0x34), 0x00, 0x44, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8), u8(t_base),
		u8(sz >> 24), u8(sz >> 16), u8(sz >> 8), u8(sz)]
	dr := ask(mut p, dl)
	assert dr[0] == 0x74
	max_data := int((u16(dr[2]) << 8 | u16(dr[3])) - 2)
	// transfer in blocks
	mut blk := u8(1)
	mut off := 0
	for off < img.len {
		mut n := img.len - off
		if n > max_data {
			n = max_data
		}
		mut req := []u8{len: 2 + n}
		req[0] = 0x36
		req[1] = blk
		for i in 0 .. n {
			req[2 + i] = img[off + i]
		}
		assert ask(mut p, req) == [u8(0x76), blk]
		off += n
		blk++
	}
	assert ask(mut p, [u8(0x37)]) == [u8(0x77)]
}

// The complete happy path: session -> unlock -> erase -> download -> transfer
// -> exit -> check (marks valid) -> the image boots (REQ-BOOT-005).
fn test_full_session_marks_valid() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	img := signed_image(700)

	unlock(mut p)
	transfer(mut p, img)
	// before the check routine: transferred but NOT valid (mark not on the wire)
	assert !check_header(&f.mem[0])
	// check routine verifies and writes the mark
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x00]
	assert check_image(&f.mem[0])
	assert decide(false, check_image(&f.mem[0])) == .run_app
	// reset completes the session
	assert ask(mut p, [u8(0x11), 0x01]) == [u8(0x51), 0x01]
	assert p.reset_pending
}

// A corrupted transfer fails the check routine and stays unbootable
// (REQ-BOOT-002/005 — the torn/corrupt update path).
fn test_corrupt_transfer_fails_check() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	mut img := signed_image(700)
	img[int(hdr_size) + 100] ^= 0x01 // corrupt one image byte after signing

	unlock(mut p)
	transfer(mut p, img)
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
	assert decide(false, check_image(&f.mem[0])) == .stay_boot
}

// REQ-BOOT-008: erase/download outside the app window is rejected — including
// the bootloader's own region (below app_base).
fn test_boot_region_protected() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock(mut p)
	// erase at the bootloader (addr 0) -> out of range
	er := [u8(0x31), 0x01, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00]
	assert ask(mut p, er) == [u8(0x7F), 0x31, 0x31]
	// erase straddling the window end -> out of range
	end := t_base + t_size - 0x100
	er2 := [u8(0x31), 0x01, 0xFF, 0x00, u8(end >> 24), u8(end >> 16), u8(end >> 8), u8(end),
		0x00, 0x00, 0x02, 0x00]
	assert ask(mut p, er2) == [u8(0x7F), 0x31, 0x31]
	assert f.erases == 0
}

// Sequence enforcement: no erase before unlock, no download before erase, no
// transfer before download, wrong block counter rejected.
fn test_sequence_guards() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	// programming session but LOCKED: erase -> securityAccessDenied
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), 0x00, 0x00, 0x10, 0x00]
	assert ask(mut p, er) == [u8(0x7F), 0x31, 0x33]
	// a wrong proof is rejected (0x29 invalidKey); a fresh challenge is required
	ch := ask(mut p, [u8(0x29), 0x01])
	assert ch[0] == 0x69
	mut bad := [u8(0x29), 0x02]
	for _ in 0 .. 64 {
		bad << 0x00
	}
	assert ask(mut p, bad) == [u8(0x7F), 0x29, 0x35]
	unlock(mut p)
	// download before erase -> sequence error
	dl := [u8(0x34), 0x00, 0x44, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8), u8(t_base),
		0x00, 0x00, 0x01, 0x00]
	assert ask(mut p, dl) == [u8(0x7F), 0x34, 0x24]
	// transfer before download -> sequence error
	assert ask(mut p, [u8(0x36), 0x01, 0xAA]) == [u8(0x7F), 0x36, 0x24]
	// after erase + download, a wrong block counter is rejected
	assert ask(mut p, er)[0] == 0x71
	assert ask(mut p, dl)[0] == 0x74
	assert ask(mut p, [u8(0x36), 0x02, 0xAA]) == [u8(0x7F), 0x36, 0x73]
}

// REQ-BOOT-009: identification DIDs answer in the default session (delegated to
// comm/uds — the bootloader's own version + app validity are example-filled).
fn test_identification_did() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.srv.dids[0].id = 0xF180
	p.srv.dids[0].data[0] = 0x01 // boot sw version major
	p.srv.dids[0].data[1] = 0x00
	p.srv.dids[0].len = 2
	p.srv.ndid = 1
	assert ask(mut p, [u8(0x22), 0xF1, 0x80]) == [u8(0x62), 0xF1, 0x80, 0x01, 0x00]
}

// Security access outside the programming session is refused (the app-facing
// surface of the bootloader stays inert in the default session).
fn test_no_unlock_in_default_session() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	assert ask(mut p, [u8(0x29), 0x01]) == [u8(0x7F), 0x29, 0x22]
}


// @verifies REQ-BOOT-013
// S3server: a silent tester loses the programming session, the unlock, and a
// half-done download; activity inside the window keeps everything alive.
fn test_s3_silence_expires_session() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock(mut p)
	p.heard(1_000_000)
	// just inside the window: session + unlock survive
	p.tick(1_000_000 + s3_server_us)
	assert p.srv.session == 0x02
	assert p.unlocked
	// past the window: default session, re-locked, download abandoned
	p.downloading = true
	p.tick(1_000_000 + s3_server_us + 1)
	assert p.srv.session == 0x01
	assert !p.unlocked
	assert !p.downloading
	// and the guarded services refuse again, exactly like a fresh boot
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), 0x00, 0x00, 0x10, 0x00]
	assert ask(mut p, er) == [u8(0x7F), 0x31, 0x33]
}

// @verifies REQ-BOOT-014
// The stay-window: default session + tester silence -> due; activity restarts
// it; a non-default session NEVER trips it (S3 owns that path); a
// never-contacted boot counts from its own start.
fn test_idle_return_window() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	t0 := u64(500_000)
	assert !p.idle_return_due(t0 + idle_return_us, t0)
	assert p.idle_return_due(t0 + idle_return_us + 1, t0)
	// tester spoke at t1: the window restarts from there
	t1 := t0 + 2_000_000
	p.heard(t1)
	assert !p.idle_return_due(t1 + idle_return_us, t0)
	assert p.idle_return_due(t1 + idle_return_us + 1, t0)
	// in a programming session the window never fires
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	assert !p.idle_return_due(t1 + 100 * idle_return_us, t0)
}

// @verifies REQ-BOOT-003
// The handoff: a boot the application entered by 0x10 02 opens the programming session the tester
// was promised — 0x29 is served at once, still locked — and a tester that then goes silent loses
// it to S3 and, past the stay-window, the ECU to its application.
fn test_a_handed_off_boot_opens_the_programming_session() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	t0 := u64(0) // the boot's clock may read 0 at the start: still a real stamp
	p.open_handed_off(t0, via_bus)
	assert p.srv.session == 0x02 && !p.unlocked
	assert ask(mut p, [u8(0x29), 0x01])[..2] == [u8(0x69), 0x01]
	// the clock may read 0 when the session opens: it survives the S3 window all the same
	for now in [t0, t0 + 1, t0 + s3_server_us] {
		p.tick(now)
		assert p.srv.session == 0x02, 'the handed-off session expired at ${now}'
		assert !p.idle_return_due(now, t0), 'the stay-window fired at ${now}'
	}
	mut q := new_prog(mut f)
	q.open_handed_off(t0, via_bus)
	q.tick(t0 + s3_server_us + 2)
	assert q.srv.session == 0x01, 'a silent tester keeps the handed-off session'
	assert q.idle_return_due(t0 + s3_server_us + idle_return_us + 2, t0)
}

// ---- P5: signed-image authenticity (REQ-BOOT-011) ----

// image/release seed (signs firmware) and tester seed (0x29) — separate keys.
const image_seed = [u8(0), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]!

const tester_seed = [u8(0x20), 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a,
	0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
	0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f]!

fn image_pubkey() [32]u8 {
	return bcrypto.public_key(image_seed)
}

fn tester_pubkey() [32]u8 {
	return bcrypto.public_key(tester_seed)
}

// signed_image = payload_image + a 64-byte Ed25519 signature over header[0..32] ‖ image,
// exactly what mkimage --sign emits and the boot verifies.
fn signed_image(image_len u32) []u8 {
	return signed_image_with(image_len, image_seed)
}

fn signed_image_with(image_len u32, seed [32]u8) []u8 {
	base := payload_image(image_len)
	mut msg := []u8{cap: 32 + int(image_len)}
	for i in 0 .. 32 {
		msg << base[i]
	}
	for i in int(hdr_size) .. base.len {
		msg << base[i]
	}
	sig := bcrypto.sign(seed, msg)
	mut out := base.clone()
	for i in 0 .. 64 {
		out << sig[i]
	}
	return out
}

// @verifies REQ-BOOT-011
fn test_signed_image_marks_valid() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.image_key = image_pubkey()
	img := signed_image(700)
	unlock(mut p)
	transfer(mut p, img)
	assert !check_header(&f.mem[0]) // not marked until the check routine verifies
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x00]
	assert check_image(&f.mem[0]) // signature checked out -> marked valid
}

// @verifies REQ-BOOT-011
fn test_signed_tamper_rejected() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.image_key = image_pubkey()
	img := signed_image(700)
	unlock(mut p)
	transfer(mut p, img)
	// flip one image byte in the flashed store (post-transfer, pre-check)
	f.mem[int(t_base - t_base) + int(hdr_size) + 100] ^= 0x01
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
}

// @verifies REQ-BOOT-011
fn test_signed_wrong_key_rejected() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	// the boot holds the dev key (session auth succeeds), but the IMAGE was
	// signed with a DIFFERENT key -> the image verify fails, no mark.
	mut other_seed := [32]u8{}
	for i in 0 .. 32 {
		other_seed[i] = image_seed[i]
	}
	other_seed[0] ^= 0xff
	img := signed_image_with(700, other_seed)
	unlock(mut p) // authenticates with the tester key (session ok); image key differs
	transfer(mut p, img)
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
}

// @verifies REQ-BOOT-011
// an UNSIGNED image is refused when a key is baked (garbage where the sig should be)
fn test_unsigned_rejected_when_key_set() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.image_key = image_pubkey()
	mut img := payload_image(700) // no signature appended
	for _ in 0 .. 64 {
		img << 0xFF // erased-looking tail where a signature would be
	}
	unlock(mut p)
	transfer(mut p, img)
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
}

// @verifies REQ-BOOT-016
// 0x29 session gate: without a matching key the tester cannot unlock, and every
// flash-write service stays refused (NRC 0x33).
fn test_0x29_wrong_proof_stays_locked() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	// a challenge, then a proof signed by the WRONG key -> invalidKey, no unlock
	ch := ask(mut p, [u8(0x29), 0x01])
	assert ch[0] == 0x69 && ch.len == 34
	mut wrong_seed := [32]u8{}
	for i in 0 .. 32 {
		wrong_seed[i] = tester_seed[i]
	}
	wrong_seed[5] ^= 0xff
	bad_sig := bcrypto.sign(wrong_seed, ch[2..34].clone())
	mut proof := [u8(0x29), 0x02]
	for i in 0 .. 64 {
		proof << bad_sig[i]
	}
	assert ask(mut p, proof) == [u8(0x7F), 0x29, 0x35]
	// still locked: erase refused
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), 0x00, 0x00, 0x10, 0x00]
	assert ask(mut p, er) == [u8(0x7F), 0x31, 0x33]
}

// @verifies REQ-BOOT-016
// proof without a prior challenge is a sequence error (no replay of a stale one)
fn test_0x29_proof_needs_challenge() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	mut proof := [u8(0x29), 0x02]
	for _ in 0 .. 64 {
		proof << 0x00
	}
	assert ask(mut p, proof) == [u8(0x7F), 0x29, 0x24]
}

// @verifies REQ-BOOT-011
// A pre-marked image (VALD already in word1, CRC-correct, NO valid signature)
// must not boot: the boot never writes the valid-mark word from the wire, so it
// stays erased and decide() finds no valid image (the pre-mark bypass).
fn test_prewritten_mark_is_dropped() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	mut img := signed_image(700)
	// forge the valid mark into the transferred header word1 (offset 32)
	img[32] = 0x56 // 'V'
	img[33] = 0x41
	img[34] = 0x4C
	img[35] = 0x44
	unlock(mut p)
	transfer(mut p, img)
	// the mark word was NOT written from the wire -> image is not valid at reset
	assert !check_image(&f.mem[0])
	assert decide(false, check_image(&f.mem[0])) == .stay_boot
	// and the legitimate path still works: check_and_mark verifies + writes it
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x00]
	assert check_image(&f.mem[0])
}

// @verifies REQ-BOOT-011, REQ-BOOT-016
// Key separation bites: a tester who authenticates with the TESTER key still
// cannot install firmware signed with that key — the image is verified against
// the IMAGE key. A leaked tester key starts sessions but never forges firmware.
fn test_key_separation_tester_cannot_forge_image() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	img := signed_image_with(700, tester_seed) // signed with the TESTER key
	unlock(mut p) // session auth succeeds (tester key)
	transfer(mut p, img)
	// image verify uses image_key, not session_key -> rejected, no mark
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
}

// @verifies REQ-BOOT-011
// A stale VALD must not survive into a new download: an erase that leaves the
// mark word intact -> request_download is refused (else a failed check would
// leave the old mark and reset would boot the new unsigned image).
fn test_stale_mark_blocks_download() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	// pre-existing valid mark in word1 (a previous good image)
	f.mem[32] = 0x56 // 'V' 'A' 'L' 'D'
	f.mem[33] = 0x41
	f.mem[34] = 0x4C
	f.mem[35] = 0x44
	unlock(mut p)
	// erase the IMAGE body but NOT the header/mark word (addr past the mark)
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8((t_base + 0x1000) >> 24), u8((t_base + 0x1000) >> 16),
		u8((t_base + 0x1000) >> 8), u8(t_base + 0x1000), 0x00, 0x00, 0x10, 0x00]
	assert ask(mut p, er)[0] == 0x71
	// download refused: the stale mark word is still 'VALD'
	dl := [u8(0x34), 0x00, 0x44, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8), u8(t_base),
		0x00, 0x00, 0x02, 0x00]
	assert ask(mut p, dl) == [u8(0x7F), 0x34, 0x22]
}

// @verifies REQ-BOOT-016
// Keyless transition build (no session key): flash-write works WITHOUT 0x29.
fn test_keyless_build_flashes_open() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.session_key = [32]u8{} // no session key -> open flashing
	p.image_key = [32]u8{} // and no image key -> no signature required
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	// erase without any 0x29 unlock -> allowed
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), u8(t_size >> 24), u8(t_size >> 16), u8(t_size >> 8), u8(t_size)]
	assert ask(mut p, er) == [u8(0x71), 0x01, 0xFF, 0x00, 0x00]
	// and an unsigned image marks valid (image_key zero -> no verify)
	img := payload_image(400)
	transfer(mut p, img)
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x00]
	assert check_image(&f.mem[0])
}

// @verifies REQ-BOOT-016
// A session change de-authenticates: after 0x10 01 then 0x10 02, the prior
// unlock is gone and erase is refused until a fresh 0x29 (no stale-unlock reuse).
fn test_session_change_clears_auth() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock(mut p) // authenticated in a programming session
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), 0x00, 0x00, 0x10, 0x00]
	assert ask(mut p, er)[0] == 0x71 // erase works while authenticated
	// bounce the session: default, then back to programming
	assert ask(mut p, [u8(0x10), 0x01])[0] == 0x50
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	// the old unlock is cleared -> erase refused until re-auth
	assert ask(mut p, er) == [u8(0x7F), 0x31, 0x33]
	unlock(mut p) // fresh 0x29
	assert ask(mut p, er)[0] == 0x71
}

// ---- two transports: the DoIP binding ----

// @verifies REQ-BOOT-019
// The programming server reached over two transports — the bus (ISO-TP) and the network (DoIP,
// through the doip thread's mailbox): the transport that opened a session holds it, a network
// reset waits for its answer to leave and dies with its connection, and a session handed off over
// the network waits for the boot's own network before S3 times it. The interleavings are checked
// against a reference model of those rules.

fn ask_net(mut p Prog, req []u8, now u64) []u8 {
	out, pushed := ask_net_held(mut p, req, now)
	if pushed {
		p.push_sent() // the routine's answer, pushed, acknowledged
	}
	return out
}

// ask_net_held: ask_net, a routine's pushed answer left unacknowledged (true when there is one)
fn ask_net_held(mut p Prog, req []u8, now u64) ([]u8, bool) {
	mut resp := []u8{len: 600}
	p.tick(now) // the serve loop ticks every pass; a network request is stamped by it
	mut n := p.serve_remote(&req[0], req.len, false, unsafe { &resp[0] })
	mut pushed := false
	for n == 3 && resp[0] == 0x7F && resp[2] == 0x78 {
		assert !p.work_due(via_net), 'a step before the pending answer was acknowledged'
		if pushed {
			p.remote_sent() // another answer's acknowledgement is not the push's
			assert !p.work_due(via_net), 'a step on another answer\'s acknowledgement'
			p.push_sent()
		} else {
			p.remote_sent() // the routine's answer to its request
		}
		assert p.work_due(via_net)
		n = p.step(now, unsafe { &resp[0] })
		pushed = true
	}
	return resp[..n], pushed
}

fn ask_via(mut p Prog, via u8, req []u8, now u64) []u8 {
	if via == via_net {
		return ask_net(mut p, req, now)
	}
	p.heard(now) // serve_step stamps a bus request before it is handled
	return ask_at(mut p, req, now)
}

// the 0x29 proof for fake_rng's challenge (the same every time)
fn proof() []u8 {
	mut ch := []u8{len: 32}
	fake_rng(unsafe { &ch[0] }, 32)
	sig := bcrypto.sign(tester_seed, ch)
	mut out := [u8(0x29), 0x02]
	for i in 0 .. 64 {
		out << sig[i]
	}
	return out
}

fn erase_req() []u8 {
	return [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), 0x00, 0x00, 0x10, 0x00]
}

fn unlock_via(mut p Prog, via u8, pf []u8, now u64) {
	assert ask_via(mut p, via, [u8(0x10), 0x02], now)[0] == 0x50
	assert ask_via(mut p, via, [u8(0x29), 0x01], now)[..2] == [u8(0x69), 0x01]
	assert ask_via(mut p, via, pf, now) == [u8(0x69), 0x02]
}

fn test_the_transport_that_opened_the_session_holds_it() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	pf := proof()
	unlock_via(mut p, via_net, pf, 0)
	// the bus cannot use the network's unlock, nor end its session
	assert ask_via(mut p, via_bus, erase_req(), 1) == [u8(0x7F), 0x31, 0x22]
	assert ask_via(mut p, via_bus, [u8(0x10), 0x01], 1) == [u8(0x7F), 0x10, 0x22]
	assert ask_via(mut p, via_net, erase_req(), 2)[0] == 0x71
	// once the holder ends its session, the other transport starts its own — locked
	assert ask_via(mut p, via_net, [u8(0x10), 0x01], 3)[0] == 0x50
	assert ask_via(mut p, via_bus, [u8(0x10), 0x02], 4)[0] == 0x50
	assert ask_via(mut p, via_bus, erase_req(), 5) == [u8(0x7F), 0x31, 0x33]
	assert ask_via(mut p, via_net, [u8(0x29), 0x01], 6) == [u8(0x7F), 0x29, 0x22]
}

fn test_a_network_reset_waits_for_its_answer_and_dies_with_the_connection() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	assert ask_net(mut p, [u8(0x11), 0x01], 0) == [u8(0x51), 0x01]
	assert !p.reset_due(), 'the answer is still on its way to the tester'
	p.remote_sent()
	assert p.reset_due()
	// the connection dropping after the answer left does not cancel it
	p.remote_dropped()
	assert p.reset_due()

	mut q := new_prog(mut f)
	assert ask_net(mut q, [u8(0x11), 0x01], 0) == [u8(0x51), 0x01]
	q.remote_dropped() // before the answer was sent: never reset unanswered
	assert !q.reset_due() && !q.reset_pending
	// a bus reset is not the network's to cancel, but it waits for a network answer in flight
	assert ask_net(mut q, [u8(0x3E), 0x00], 1) == [u8(0x7E), 0x00]
	assert ask_via(mut q, via_bus, [u8(0x11), 0x01], 2) == [u8(0x51), 0x01]
	assert !q.reset_due()
	q.remote_dropped()
	assert q.reset_due()
	// nothing is served once a reset is pending, over either transport
	assert ask_via(mut q, via_bus, [u8(0x3E), 0x00], 3) == []u8{}
	assert ask_net(mut q, [u8(0x3E), 0x00], 3) == []u8{}
}

fn test_a_dropped_connection_ends_the_session_it_held() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock_via(mut p, via_net, proof(), 0)
	p.remote_sent()
	p.remote_dropped()
	assert p.srv.session == 0x01 && !p.unlocked
	// one the bus holds is not the network's to end
	unlock_via(mut p, via_bus, proof(), 1)
	p.remote_dropped()
	assert p.srv.session == 0x02 && p.unlocked
}

fn test_a_functional_network_request_is_acknowledged_unanswered() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	req := [u8(0x10), 0x02]
	mut resp := []u8{len: 64}
	assert p.serve_remote(&req[0], 2, true, unsafe { &resp[0] }) == 0
	assert p.srv.session == 0x01
	assert p.remote.inflight, 'its acknowledgement still goes out'
}

// The handoff over DoIP: the application answered 50 02 and reset, and the tester reconnects once
// the boot's network is up. S3 does not run before then — no tester can reach the boot — and runs
// in full from then; a network that never comes up gives the ECU back within net_wait_default_us.
fn test_a_session_handed_off_over_the_network_waits_for_the_network() {
	mut f := &TestFlash{}
	t0 := u64(1_000)
	up := t0 + 7_000_000 // a slow link: longer than S3 after the reset
	mut p := new_prog(mut f)
	p.open_handed_off(t0, via_net)
	p.tick(up - 1)
	assert p.srv.session == 0x02, 'S3 ran before the network was up'
	assert !p.idle_return_due(up - 1, t0)
	p.net_up(up)
	p.tick(up + s3_server_us)
	assert p.srv.session == 0x02, 'S3 counts from the network coming up'
	// the tester that reconnects goes on with 0x29 at once, as over the bus
	assert ask_net(mut p, [u8(0x29), 0x01], up + s3_server_us)[..2] == [u8(0x69), 0x01]
	// and the bus cannot take its session
	assert ask_via(mut p, via_bus, [u8(0x29), 0x01], up + s3_server_us) == [u8(0x7F), 0x29, 0x22]

	// silent after the network came up: S3, then the stay-window, as for any handoff
	mut q := new_prog(mut f)
	q.open_handed_off(t0, via_net)
	q.net_up(up)
	q.tick(up + s3_server_us + 1)
	assert q.srv.session == 0x01
	assert q.idle_return_due(up + idle_return_us + 1, t0)

	// a network that never comes up: the session ends at net_wait_default_us, and the ECU goes back
	mut r := new_prog(mut f)
	r.open_handed_off(t0, via_net)
	r.tick(t0 + net_wait_default_us)
	assert r.srv.session == 0x02
	r.tick(t0 + net_wait_default_us + 1)
	assert r.srv.session == 0x01
	assert r.idle_return_due(t0 + net_wait_default_us + 1, t0), 'parked past the bound'
	// net_up after the bound changes nothing
	r.net_up(t0 + net_wait_default_us + 2)
	assert r.srv.session == 0x01

	// over the bus there is nothing to wait for: S3 from the handoff
	mut b := new_prog(mut f)
	b.open_handed_off(t0, via_bus)
	b.tick(t0 + s3_server_us + 1)
	assert b.srv.session == 0x01
}

// a request the other transport's session refuses keeps nothing alive
fn test_a_refused_request_does_not_hold_the_other_transports_session() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock_via(mut p, via_bus, proof(), 0)
	for t := u64(1_000_000); t <= s3_server_us; t += 1_000_000 {
		assert ask_net(mut p, [u8(0x3E), 0x00], t) == [u8(0x7F), 0x3E, 0x22]
		p.remote_sent()
		p.tick(t)
	}
	p.tick(s3_server_us + 1)
	assert p.srv.session == 0x01 && !p.unlocked, 'the network kept the bus session alive'
}

// a DoIP answer whose acknowledgement is slow holds the session past S3, as a bus answer still
// being sent does; once acknowledged, S3 runs from then
fn test_a_slow_acknowledgement_holds_s3() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock_via(mut p, via_net, proof(), 0)
	p.tick(3 * s3_server_us) // the 0x29 answer still unacknowledged
	assert p.srv.session == 0x02 && p.unlocked
	p.remote_sent()
	p.tick(4 * s3_server_us)
	assert p.srv.session == 0x02, 'S3 runs from the last exchange in flight'
	p.tick(4 * s3_server_us + 1)
	assert p.srv.session == 0x01
	// nor does the stay-window give the ECU back while it is in flight
	mut q := new_prog(mut f)
	assert ask_net(mut q, [u8(0x3E), 0x00], 0)[0] == 0x7E
	q.tick(5 * idle_return_us)
	assert !q.idle_return_due(5 * idle_return_us, 0)
}

// the most a valid [doip] policy announces (doip.announce_total_max_ms, 10 x 1000 ms) plus a slow
// link start-up: the node's bound covers it, so the handed-off session is still there when the
// listener opens at the last moment the policy allows
fn test_the_network_wait_covers_the_longest_announcement_sequence() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	link_ms := u64(5000) // loom2v doip_link_allowance_ms
	p.net_wait_us = (link_ms + 10 * 1000) * 1000 // BOOT_DOIP_NET_WAIT_MS at the policy maximum
	p.open_handed_off(0, via_net)
	up := p.net_wait_us // the listener opens at the very end of the wait
	p.tick(up)
	assert p.srv.session == 0x02, 'the wait ran out before a valid policy could open the listener'
	p.net_up(up)
	p.tick(up + s3_server_us)
	assert p.srv.session == 0x02
	assert ask_net(mut p, [u8(0x29), 0x01], up + s3_server_us)[..2] == [u8(0x69), 0x01]
}

// a reset the network asked for is not cancelled by a bus answer the controller refused
fn test_a_bus_failure_does_not_cancel_a_network_reset() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	assert ask_net(mut p, [u8(0x11), 0x01], 0) == [u8(0x51), 0x01]
	p.cancel_reset() // comm/diag serve_step: a bus frame refused
	p.remote_sent()
	assert p.reset_due()
}

// a handed-off session waits for ITS tester: a connection that drops before any request does not
// end it — one that spoke in it and drops does
fn test_a_handoff_survives_a_connection_that_never_spoke() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.open_handed_off(0, via_net)
	p.net_up(1)
	p.remote_dropped()
	assert p.srv.session == 0x02
	assert ask_net(mut p, [u8(0x29), 0x01], 2)[..2] == [u8(0x69), 0x01]
	p.remote_sent()
	p.remote_dropped()
	assert p.srv.session == 0x01 && !p.challenge_valid
}

// ---- the reference model ----

struct Model {
mut:
	session   u8
	owner     u8
	unlocked  bool
	challenge bool
	pending   bool // a reset answered
	remote    bool // ... asked over the network
	inflight  bool
	spoke     bool // the network has been heard in the session it holds
	push      bool // a routine's answer pushed over the network, not yet acknowledged
	heard     u64
}

fn (mut m Model) end() {
	m.session = 0x01
	m.owner = 0
	m.unlocked = false
	m.challenge = false
	m.spoke = false
	m.push = false
}

// request: the answer the rules give (its first bytes: the positive SID, or 7F SID NRC)
fn (mut m Model) request(via u8, req []u8, now u64) []u8 {
	if via == via_net {
		m.inflight = true
	}
	if m.pending {
		return []u8{}
	}
	sid := req[0]
	if m.session != 0x01 && m.owner != via {
		return [u8(0x7F), sid, 0x22] // and keeps nothing alive
	}
	m.heard = now
	mut out := []u8{}
	match sid {
		0x10 {
			m.session = req[1]
			m.unlocked = false
			m.challenge = false
			out = [u8(0x50), req[1]]
		}
		0x29 {
			if m.session != 0x02 {
				out = [u8(0x7F), 0x29, 0x22]
			} else if req[1] == 0x01 {
				m.challenge = true
				out = [u8(0x69), 0x01]
			} else if !m.challenge {
				out = [u8(0x7F), 0x29, 0x24]
			} else {
				m.challenge = false
				m.unlocked = true
				out = [u8(0x69), 0x02]
			}
		}
		0x31 {
			out = if m.session == 0x02 && m.unlocked { [u8(0x71)] } else { [u8(0x7F), 0x31, 0x33] }
		}
		0x11 {
			m.pending = true
			m.remote = via == via_net
			out = [u8(0x51), 0x01]
		}
		else {
			out = [u8(0x7E)]
		}
	}
	m.owner = if m.session == 0x01 { u8(0) } else { via }
	m.spoke = m.owner == via_net
	return out
}

fn (mut m Model) dropped() {
	if m.inflight && m.remote {
		m.pending = false
	}
	m.inflight = false
	m.remote = false
	m.push = false // nobody acknowledges it now: the routine goes with the connection
	if m.owner == via_net && m.spoke {
		m.end()
	}
}

fn (mut m Model) tick(now u64) {
	if m.inflight && (m.session == 0x01 || m.owner == via_net) {
		m.heard = now // an exchange in flight holds the silence clocks
	}
	if m.push {
		m.heard = now // ... and so does a routine's answer on its way
	}
	if m.session != 0x01 && now - m.heard > s3_server_us {
		m.end()
	}
}

fn (m &Model) reset_due() bool {
	return m.pending && !m.inflight
}

fn fresh_model() Model {
	return Model{
		session: 0x01
	}
}

// what the model compares: the positive SID, or the negative answer whole
fn shape(a []u8) []u8 {
	if a.len == 0 {
		return a
	}
	if a[0] == 0x7F {
		return a[..3]
	}
	if a[0] == 0x50 || a[0] == 0x51 || a[0] == 0x69 {
		return a[..2]
	}
	return a[..1]
}

fn test_two_transports_against_the_reference_model() {
	rand.seed([u32(0x0B007), 0x13400])
	pf := proof()
	reqs := [[u8(0x10), 0x01], [u8(0x10), 0x02], [u8(0x10), 0x03], [u8(0x29), 0x01], pf,
		erase_req(), [u8(0x11), 0x01], [u8(0x3E), 0x00]]
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	mut m := fresh_model()
	mut now := u64(0)
	mut resets := 0
	mut held_s3 := 0 // S3 passed with a routine's pushed answer unacknowledged
	// the DoIP mailbox and connection under the serve loop, through the target's own rules
	// (driver/eth/doip_mb.h; its protocol has its own model, driver/eth/doip_mb_test.v): the
	// connection and its unacknowledged bytes
	mut mb := C.doip_mb_t{}
	mut connected := 1
	mut unacked := u32(0)
	for step in 0 .. 2000 {
		op := rand.intn(13) or { 0 }
		now += u64(rand.intn(400_000) or { 0 })
		p.tick(now) // the serve loop ticks every pass, before it serves
		m.tick(now)
		match op {
			0...7 {
				via := if rand.intn(2) or { 0 } == 0 { via_bus } else { via_net }
				// half the time the next request on the way to an erase, so routines run often
				req := if rand.intn(2) or { 0 } == 0 {
					reqs[rand.intn(reqs.len) or { 0 }]
				} else if m.session != 0x02 {
					[u8(0x10), 0x02]
				} else if m.unlocked {
					erase_req()
				} else if m.challenge {
					pf
				} else {
					[u8(0x29), 0x01]
				}
				if via == via_net {
					connected = 1 // a tester connects (again)
					C.doip_mb_post(&mb)
				}
				// over the network a routine's pushed answer may stay unacknowledged (op 11 acks it)
				mut raw := []u8{}
				mut routine := false
				if via == via_net {
					raw, routine = ask_net_held(mut p, req, now)
				} else {
					raw = ask_via(mut p, via, req, now)
				}
				got := shape(raw)
				want := m.request(via, req, now)
				if routine {
					// its 0x78 — the answer to the request — was acknowledged on the way
					m.inflight = false
					if rand.intn(2) or { 0 } == 0 {
						m.push = true
					} else {
						p.push_sent()
					}
				}
				assert got == want, 'step ${step}: ${req[0]:02X} via ${via}: got ${got} want ${want}'
				if via == via_net {
					// served, and its answer handed to TCP over the connection it came on
					C.doip_mb_serve(&mb)
					C.doip_mb_queue(&mb)
					unacked = 1
				}
			}
			8 {
				unacked = 0 // the tester acknowledged what is queued
			}
			9 {
				// the connection drops — its unacknowledged bytes with it — and the doip thread
				// recycles it
				connected = 0
				unacked = 0
				C.doip_mb_drop(&mb)
			}
			10 {
				now += s3_server_us
			}
			11 {
				p.push_sent() // the pushed answer's own acknowledgement
				m.push = false
			}
			else {}
		}
		// the serve loop's mailbox pass (doipnet.serve_mailbox): an answer is sent once acknowledged
		// on a live connection, and a drop is reported
		state := if connected == 1 { u32(5) } else { u32(1) } // ESTABLISHED / CLOSED (NetX)
		if C.doip_mb_sent_take(&mb, state, unacked) == 1 {
			assert connected == 1 && unacked == 0
			p.remote_sent()
			m.inflight = false
		}
		if C.doip_mb_dropped_take(&mb) == 1 {
			p.remote_dropped()
			m.dropped()
		}
		p.tick(now)
		m.tick(now)
		assert p.srv.session == m.session, 'step ${step}: session'
		assert p.unlocked == m.unlocked, 'step ${step}: unlock'
		assert p.reset_due() == m.reset_due(), 'step ${step}: reset due'
		if op == 10 && m.push && m.session != 0x01 {
			held_s3++
		}
		if p.reset_due() {
			// never with a network answer queued unacknowledged (the reset would kill it)
			assert !(m.remote && unacked != 0), 'step ${step}: reset with its answer unacknowledged'
			// the owner resets the MCU: both start over
			p = new_prog(mut f)
			m = fresh_model()
			resets++
		}
	}
	assert resets > 10, 'the walk never reached a reset'
	assert held_s3 > 0, 'the walk never held a session on an unacknowledged answer'
}

// the boot's identification DIDs: added in order, read back by 0x22 — the DoIP boot's VIN (F190)
// among them, as its application answers it; a table that is full adds nothing
fn test_identification_dids_are_added_and_served() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.srv.ndid = 0
	vin := 'BLOBLYSYSNODEH735'.bytes()
	assert p.add_did(0xF190, &vin[0], 17)
	r := ask(mut p, [u8(0x22), 0xF1, 0x90])
	assert r[..3] == [u8(0x62), 0xF1, 0x90] && r[3..].bytestr() == 'BLOBLYSYSNODEH735'
	big := []u8{len: 33}
	assert !p.add_did(0x0100, &big[0], 33), 'longer than a DID holds'
	for p.srv.ndid < 16 {
		assert p.add_did(u16(0x0200 + p.srv.ndid), &vin[0], 1)
	}
	assert !p.add_did(0x0300, &vin[0], 1), 'a full table'
	assert p.srv.ndid == 16
}

// ---- routine work answered pending ----

// a multi-sector erase answers responsePending, then erases ONE unit per step — the owner sends
// each response before the next step (a sector erase stalls a single-bank chip whole) — with a
// 0x78 between units and the routine's answer after the last: every response is one unit's erase
// time after the one before it (a 128 KB H7 sector: about 1-2 s), never past P2* (5 s)
fn test_an_erase_answers_pending_and_steps_one_unit_at_a_time() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.erase_unit = 0x4000 // four units in the 64 KB test window
	unlock(mut p)
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), u8(t_size >> 24), u8(t_size >> 16), u8(t_size >> 8), u8(t_size)]
	mut resp := []u8{len: 64}
	mut n := p.handle(&er[0], er.len, unsafe { &resp[0] })
	assert resp[..n] == [u8(0x7F), 0x31, 0x78], 'answered pending, nothing erased yet'
	assert f.erases == 0
	// a request while it runs is told to come back
	tp := [u8(0x3E), 0x00]
	mut r2 := []u8{len: 8}
	assert p.handle(&tp[0], 2, unsafe { &r2[0] }) == 3 && r2[2] == 0x21
	mut pendings := 0
	for step in 1 .. 10 {
		assert !p.work_due(via_bus), 'a unit before its 0x78 left'
		p.work_left() // the 0x78 is on the wire
		assert p.work_due(via_bus)
		n = p.step(u64(step) * 2_000_000, unsafe { &resp[0] })
		assert f.erases == step, 'one unit per step'
		if resp[..n] == [u8(0x7F), 0x31, 0x78] {
			pendings++
			continue
		}
		break
	}
	assert pendings == 3
	assert resp[..n] == [u8(0x71), 0x01, 0xFF, 0x00, 0x00]
	assert !p.work_due(via_bus) && p.erased
	// the steps are tester activity: S3 does not expire under a long erase
	p.tick(4 * 2_000_000 + s3_server_us)
	assert p.srv.session == 0x02
}

// over the network each step waits for the previous response to be acknowledged, and its own
// response is in flight until it is; a connection that drops takes the routine with it
fn test_a_network_erase_steps_only_on_acknowledgement() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.erase_unit = 0x8000
	unlock_via(mut p, via_net, proof(), 0)
	p.remote_sent()
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), u8(t_size >> 24), u8(t_size >> 16), u8(t_size >> 8), u8(t_size)]
	mut resp := []u8{len: 64}
	assert p.serve_remote(&er[0], er.len, false, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
	assert !p.work_due(via_net) && !p.work_due(via_bus)
	p.remote_sent()
	assert p.work_due(via_net)
	assert p.step(1, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
	assert !p.work_due(via_net), 'the next step waits for this response to be acknowledged'
	// a request pipelined behind it is answered busy and acknowledged — not the push's own
	tp := [u8(0x3E), 0x00]
	assert p.serve_remote(&tp[0], 2, false, unsafe { &resp[0] }) == 3 && resp[2] == 0x21
	p.remote_sent()
	assert !p.work_due(via_net), 'a step on another answer\'s acknowledgement'
	p.remote_dropped()
	assert !p.work_due(via_net) && f.erases == 1, 'nobody waits for the rest'
}

// the check routine is answered pending too, and done in one step
fn test_the_check_routine_answers_pending() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock(mut p)
	transfer(mut p, signed_image(300))
	ck := [u8(0x31), 0x01, 0xFF, 0x01]
	mut resp := []u8{len: 64}
	assert p.handle(&ck[0], 4, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
	assert p.step(0, unsafe { &resp[0] }) == 0, 'not before the 0x78 left'
	p.work_left()
	assert p.step(0, unsafe { &resp[0] }) == 5
	assert resp[..5] == [u8(0x71), 0x01, 0xFF, 0x01, 0x00]
}

// an acknowledged reset answer is not cancelled by a request pipelined behind it whose connection
// drops: TCP acknowledged the reset's answer, which is all a reset waits for
fn test_an_acknowledged_reset_survives_a_pipelined_request_that_drops() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	assert ask_net(mut p, [u8(0x11), 0x01], 0) == [u8(0x51), 0x01]
	p.remote_sent() // A acknowledged
	assert ask_net(mut p, [u8(0x3E), 0x00], 1) == []u8{}, 'B: acknowledged by DoIP, unanswered'
	assert !p.reset_due(), 'B is in flight'
	p.remote_dropped() // B's connection drops
	assert p.reset_due(), 'the acknowledged reset is cancelled'
}

// a routine's 0x78 the bus lost (refused, aborted) goes again before any unit runs; lost every
// time, the routine ends refused after work_resend_max tries — never the work unannounced
fn test_a_lost_pending_answer_is_sent_again_before_any_unit() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.erase_unit = 0x4000
	unlock(mut p)
	er := [u8(0x31), 0x01, 0xFF, 0x00, u8(t_base >> 24), u8(t_base >> 16), u8(t_base >> 8),
		u8(t_base), u8(t_size >> 24), u8(t_size >> 16), u8(t_size >> 8), u8(t_size)]
	mut resp := []u8{len: 64}
	p.handle(&er[0], er.len, unsafe { &resp[0] })
	p.work_lost()
	assert p.step(0, unsafe { &resp[0] }) == 3 && resp[2] == 0x78 && f.erases == 0, 'said again, nothing erased'
	p.work_left()
	assert p.step(1, unsafe { &resp[0] }) == 3 && resp[2] == 0x78 && f.erases == 1
	for _ in 0 .. work_resend_max {
		p.work_lost()
		assert p.step(2, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
	}
	p.work_lost()
	assert p.step(3, unsafe { &resp[0] }) == 3 && resp[1] == 0x31 && resp[2] == 0x72, 'given up, refused'
	assert f.erases == 1 && p.work != 0, 'the refusal on its way'
	p.work_left()
	assert p.work == 0
}

// the routine's answer is in flight until confirmed, like its 0x78s: over the network a pushed
// answer whose acknowledgement is late holds S3 — the tester's next download finds the session
// it was answered in — and its acknowledgement ends the routine; a connection that drops takes it
fn test_a_pushed_answer_holds_the_session_until_acknowledged() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock_via(mut p, via_net, proof(), 0)
	p.remote_sent()
	er := erase_req()
	mut resp := []u8{len: 64}
	assert p.serve_remote(&er[0], er.len, false, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
	p.remote_sent()
	assert p.step(1, unsafe { &resp[0] }) == 5 && resp[0] == 0x71, 'erased, answered'
	assert !p.work_due(via_net), 'nothing to do until it is acknowledged'
	p.remote_sent() // another answer's acknowledgement is not the push's
	// a request meanwhile is served (the routine is done) and releases nothing
	tp := [u8(0x3E), 0x00]
	assert p.serve_remote(&tp[0], 2, false, unsafe { &resp[0] }) == 2 && resp[0] == 0x7E
	p.remote_sent()
	assert p.work != 0 && p.work_push, 'a served request released the pushed answer'
	p.tick(1 + 2 * s3_server_us)
	assert p.srv.session == 0x02, 'S3 ran out under an answer still on its way'
	p.push_sent()
	assert p.work == 0, 'acknowledged: the routine is over'
	p.tick(2 + 2 * s3_server_us)
	assert p.srv.session == 0x02, 'S3 starts from the acknowledgement'
	p.tick(3 + 3 * s3_server_us)
	assert p.srv.session == 0x01, 'and then runs'
	// never acknowledged: the connection drops and takes the routine with it
	mut q := new_prog(mut f)
	unlock_via(mut q, via_net, proof(), 0)
	q.remote_sent()
	q.serve_remote(&er[0], er.len, false, unsafe { &resp[0] })
	q.remote_sent()
	q.step(1, unsafe { &resp[0] })
	q.remote_dropped()
	assert q.work == 0 && q.srv.session == 0x01
	// ... also once the session has moved on to the bus: nothing is left holding it
	mut r := new_prog(mut f)
	unlock_via(mut r, via_net, proof(), 0)
	r.remote_sent()
	r.serve_remote(&er[0], er.len, false, unsafe { &resp[0] })
	r.remote_sent()
	r.step(1, unsafe { &resp[0] })
	assert ask_net(mut r, [u8(0x10), 0x01], 2)[0] == 0x50
	assert ask_via(mut r, via_bus, [u8(0x10), 0x02], 3)[0] == 0x50
	r.remote_dropped()
	assert r.work == 0, 'a routine answer nobody will acknowledge'
	r.tick(4 + s3_server_us)
	assert r.srv.session == 0x01, 'S3 held for ever'
}

// a routine's answer the bus lost goes again — the work is not done twice — and lost every time it
// is given up after work_resend_max tries: the routine ends, nothing holds the session for ever
fn test_a_lost_answer_is_sent_again_then_given_up() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	unlock(mut p)
	er := erase_req()
	mut resp := []u8{len: 64}
	p.handle(&er[0], er.len, unsafe { &resp[0] })
	p.work_left()
	assert p.step(0, unsafe { &resp[0] }) == 5 && resp[0] == 0x71
	erases := f.erases
	for i in 0 .. work_resend_max {
		p.work_lost()
		assert p.work_due(via_bus)
		mut again := []u8{len: 64}
		assert p.step(u64(i), unsafe { &again[0] }) == 5 && again[..5] == resp[..5], 'the same answer'
		assert f.erases == erases, 'not erased again'
	}
	p.work_lost()
	assert p.step(9, unsafe { &resp[0] }) == 0 && p.work == 0, 'given up'
	p.tick(10 + s3_server_us)
	assert p.srv.session == 0x01, 'S3 runs again'
	// lost once, then confirmed: over
	mut q := new_prog(mut f)
	unlock(mut q)
	q.handle(&er[0], er.len, unsafe { &resp[0] })
	q.work_left()
	q.step(0, unsafe { &resp[0] })
	q.work_lost()
	q.step(1, unsafe { &resp[0] })
	q.work_left()
	assert q.work == 0 && !q.work_due(via_bus)
}
