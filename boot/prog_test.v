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
	p.init() // the target-required seed/session path, exercised by every test
	return p
}

// ask: one request/response exchange; returns the response bytes.
fn ask(mut p Prog, req []u8) []u8 {
	mut resp := []u8{len: 600}
	n := p.handle(&req[0], req.len, unsafe { &resp[0] })
	return resp[..n]
}

fn unlock(mut p Prog) {
	assert ask(mut p, [u8(0x10), 0x02])[0] == 0x50 // programming session
	seed_rsp := ask(mut p, [u8(0x27), 0x01])
	assert seed_rsp[0] == 0x67
	seed := (u32(seed_rsp[2]) << 24) | (u32(seed_rsp[3]) << 16) | (u32(seed_rsp[4]) << 8) | u32(seed_rsp[5])
	key := expected_key(seed)
	assert ask(mut p, [u8(0x27), 0x02, u8(key >> 24), u8(key >> 16), u8(key >> 8), u8(key)]) == [
		u8(0x67),
		0x02,
	]
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
	img := payload_image(700)

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
	mut img := payload_image(700)
	img[100] ^= 0x01 // corrupt one payload byte AFTER the CRC was computed

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
	// wrong key locks the seed handshake again
	seed_rsp := ask(mut p, [u8(0x27), 0x01])
	assert seed_rsp[0] == 0x67
	assert ask(mut p, [u8(0x27), 0x02, 0xDE, 0xAD, 0xBE, 0xEF]) == [u8(0x7F), 0x27, 0x35]
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
	assert ask(mut p, [u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x22]
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

const dev_seed = [u8(0), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]!

fn dev_pubkey() [32]u8 {
	return bcrypto.public_key(dev_seed)
}

// signed_image = payload_image + a 64-byte Ed25519 signature over header[0..32] ‖ image,
// exactly what mkimage --sign emits and the boot verifies.
fn signed_image(image_len u32) []u8 {
	base := payload_image(image_len)
	mut msg := []u8{cap: 32 + int(image_len)}
	for i in 0 .. 32 {
		msg << base[i]
	}
	for i in int(hdr_size) .. base.len {
		msg << base[i]
	}
	sig := bcrypto.sign(dev_seed, msg)
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
	p.pubkey = dev_pubkey()
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
	p.pubkey = dev_pubkey()
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
	// bake a DIFFERENT key than the one that signed
	mut other_seed := [32]u8{}
	for i in 0 .. 32 {
		other_seed[i] = dev_seed[i]
	}
	other_seed[0] ^= 0xff
	p.pubkey = bcrypto.public_key(other_seed)
	img := signed_image(700) // signed with dev_seed
	unlock(mut p)
	transfer(mut p, img)
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
}

// @verifies REQ-BOOT-011
// an UNSIGNED image is refused when a key is baked (garbage where the sig should be)
fn test_unsigned_rejected_when_key_set() {
	mut f := &TestFlash{}
	mut p := new_prog(mut f)
	p.pubkey = dev_pubkey()
	mut img := payload_image(700) // no signature appended
	for _ in 0 .. 64 {
		img << 0xFF // erased-looking tail where a signature would be
	}
	unlock(mut p)
	transfer(mut p, img)
	assert ask(mut p, [u8(0x31), 0x01, 0xFF, 0x01]) == [u8(0x71), 0x01, 0xFF, 0x01, 0x01]
	assert !check_image(&f.mem[0])
}
