module boot

import bcrypto

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

// ask: one request/response exchange; returns the response bytes.
fn ask(mut p Prog, req []u8) []u8 {
	mut resp := []u8{len: 600}
	n := p.handle(&req[0], req.len, unsafe { &resp[0] })
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
	p.last_rx_us = 1_000_000
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
	p.last_rx_us = t1
	assert !p.idle_return_due(t1 + idle_return_us, t0)
	assert p.idle_return_due(t1 + idle_return_us + 1, t0)
	// in a programming session the window never fires
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50
	assert !p.idle_return_due(t1 + 100 * idle_return_us, t0)
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
