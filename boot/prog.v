module boot

// The programming session — UDS services 0x29/0x31/0x34/0x36/0x37/0x11 layered
// on comm/uds's Server (which keeps 0x10/0x22/0x2E/0x3E). Transport-agnostic by
// construction (REQ-BOOT-006): requests arrive as reassembled byte blocks from
// WHATEVER transport binding feeds it (ISO-TP/CAN today, DoIP later), and block
// pacing is the transport's business — this layer sees only bytes.
//
// Flash access goes through FlashOps hooks so the same session logic runs against
// RAM in unit tests, a file in the vcan simulator, and the boards-layer flash
// driver on target. Program granularity is `prog_word` bytes (32 on STM32H7) —
// transfer data is staged and programmed in whole words; the tail pads with 0xFF.

import comm.uds
import bcrypto

pub const prog_word = u32(32) // program granularity (STM32H7 flash word)
pub const max_block_data = 512 // 0x36 payload cap advertised in the 0x34 response

// negative-response codes used here
const nrc_incorrect_length = u8(0x13)
const nrc_conditions_not_correct = u8(0x22)
const nrc_request_sequence_error = u8(0x24)
const nrc_request_out_of_range = u8(0x31)
const nrc_security_access_denied = u8(0x33)
const nrc_invalid_key = u8(0x35)
const nrc_general_programming_failure = u8(0x72)
const nrc_wrong_block_sequence = u8(0x73)

// routine ids (0x31 sub 0x01 = start)
pub const routine_erase = u16(0xFF00)
pub const routine_check = u16(0xFF01)

// FlashOps: the target seam (ctx-carrying hooks, the trace-hook pattern — the
// target passes nil and plain functions; tests/sims pass their backing store).
// All addresses are absolute; program len is a multiple of the program unit and
// the region was erased first.
//
// Driver contract notes (portability — the reasons these are HOOKS):
//   - `read` must be fault-tolerant on ECC flashes: a torn (power-cut) word can
//     raise an ECC double-error on read (STM32H7) — the driver absorbs that and
//     returns the bytes it can (garbage is fine; CRC layers above reject it).
//   - `program` failure may still have touched the word: callers must treat a
//     failed program's address as CONSUMED (never re-program it — illegal on
//     ECC flash). When one call spans several hardware pages, pages program in
//     ascending address order, so a cut leaves a prefix + blank/torn tail.
//   - `blank` answers "is this ENTIRE range erased?" (AND over all pages). nil
//     = the caller may use the all-0xFF pattern test (ST/most NOR). On flashes
//     where blankness is a hardware question, not a readable pattern (Infineon
//     DFLASH blank-check), and on ECC parts where a torn word can READ as
//     erased while being unprogrammable, the driver MUST provide it.
pub struct FlashOps {
pub mut:
	ctx     voidptr = unsafe { nil }
	erase   fn (ctx voidptr, addr u32, size u32) bool = unsafe { nil }
	program fn (ctx voidptr, addr u32, data &u8, len u32) bool = unsafe { nil }
	read    fn (ctx voidptr, addr u32, out &u8, len u32) bool = unsafe { nil }
	blank   fn (ctx voidptr, addr u32, len u32) bool = unsafe { nil }
}

// Prog is the bootloader's UDS server: the app region it may touch, the flash
// hooks, and the transfer state machine. Everything fixed-size.
pub struct Prog {
pub mut:
	srv   uds.Server // 0x10/0x22/0x2E/0x3E delegate (sessions, identification DIDs)
	flash FlashOps
	// the ONLY writable window (REQ-BOOT-008): everything outside — including
	// the bootloader's own region — is rejected at erase and download time.
	app_base u32
	app_size u32
	// TWO separate trust anchors — different keys, different custody (see
	// examples/keys). The private halves are NEVER on the ECU.
	//   image_key   — verifies the firmware signature (REQ-BOOT-011). Its private
	//                 half is the RELEASE key (mkimage.seed), an offline/HSM key
	//                 in the build pipeline. Leak ⇒ forged firmware (catastrophic).
	//   session_key — verifies the 0x29 proof (REQ-BOOT-016). Its private half is
	//                 the TESTER key (tester.seed), out in the field with the
	//                 technician. Leak ⇒ start sessions only (annoyance, not RCE).
	// All-zero disables the respective check (tests / a transition build).
	image_key   [32]u8
	session_key [32]u8
	// 0x29 challenge source: the board's TRNG on target, a deterministic source
	// in tests. A null rng leaves the session unlockable (fail-closed).
	rng fn (out &u8, n int) bool = unsafe { nil }
	unlocked        bool
	challenge       [32]u8
	challenge_valid bool
	// transfer state
	erased     bool
	downloading bool
	dl_addr    u32 // next absolute write address
	dl_end     u32
	next_block u8
	// tester-silence clocks (REQ-BOOT-013/014): handle() stamps last_rx_us,
	// tick() expires the session, idle_return_due() answers the stay-window
	last_rx_us u64
	// stage buffer: fills to prog_word, then programs
	stage     [32]u8
	stage_len u32
	// set by 0x11 after the positive response is sent — the owner loop resets
	reset_pending bool
}

// handle: boot services first, everything else delegated to comm/uds.
pub fn (mut p Prog) handle(req &u8, req_len int, resp &u8) int {
	if req_len < 1 {
		return 0
	}
	sid := unsafe { req[0] }
	match sid {
		0x29 { return p.authentication(req, req_len, resp) }
		0x31 { return p.routine_control(req, req_len, resp) }
		0x34 { return p.request_download(req, req_len, resp) }
		0x36 { return p.transfer_data(req, req_len, resp) }
		0x37 { return p.transfer_exit(req, req_len, resp) }
		0x11 { return p.ecu_reset(req, req_len, resp) }
		else { return p.srv.handle(req, req_len, resp) }
	}
}

// init sets the state a freshly-booted programming service runs with. Field
// defaults can't (a __global's initializers live in the never-called _vinit on
// freestanding targets — the H755 bench found seed reading 0 = the
// already-unlocked convention), so every consumer calls this first.
pub fn (mut p Prog) init() {
	p.srv.session = 0x01 // default diagnostic session (0x29 auth stays LOCKED)
}

// S3server (ISO 14229): a non-default session dies after 5 s of tester silence.
pub const s3_server_us = u64(5_000_000)

// The boot-stay window (REQ-BOOT-014): entered-by-request + valid app + default
// session + this much silence -> give the ECU back to the application.
pub const idle_return_us = u64(10_000_000)

// tick expires the diagnostic session on tester silence (REQ-BOOT-013): back to
// the default session, security re-locked, a half-done download abandoned (the
// torn image is refused by the valid-mark-last rule anyway — conservative wins).
// Call it from the serve loop; handle() stamps the activity clock.
pub fn (mut p Prog) tick(now u64) {
	if p.srv.session != 0x01 && p.last_rx_us != 0 && now - p.last_rx_us > s3_server_us {
		p.srv.session = 0x01
		p.unlocked = false
		p.challenge_valid = false
		p.downloading = false
		p.erased = false
	}
}

// idle_return_due: the serve loop's exit question (REQ-BOOT-014). Only in the
// default session — an ACTIVE tester (incl. TesterPresent) never trips it —
// and only the caller knows whether boot was entered by request over a valid
// app (with no valid app there is nothing to return to: keep serving).
pub fn (p &Prog) idle_return_due(now u64, boot_start_us u64) bool {
	if p.srv.session != 0x01 {
		return false
	}
	last := if p.last_rx_us != 0 { p.last_rx_us } else { boot_start_us }
	return now - last > idle_return_us
}

fn (mut p Prog) in_programming_session() bool {
	return p.srv.session == 0x02
}

// write_locked: flash-write services (erase/download/check) require a passed
// 0x29 unlock — UNLESS no session key is baked, in which case a keyless
// transition/dev build flashes openly (REQ-BOOT-016). Independent of image_key:
// a build can require signed images without a session gate, or vice versa.
fn (p &Prog) write_locked() bool {
	return !p.unlocked && !key_is_zero(p.session_key)
}

// region_ok: [addr, addr+size) inside the app window, non-empty, no overflow.
fn (p Prog) region_ok(addr u32, size u32) bool {
	if size == 0 {
		return false
	}
	end := u64(addr) + u64(size)
	return addr >= p.app_base && end <= u64(p.app_base) + u64(p.app_size)
}

// 0x29 Authentication (REQ-BOOT-016): a simplified challenge/response profile —
// sub 0x01 requestChallenge, sub 0x02 verifyProofOfOwnership. The boot draws a
// random challenge, the tester returns an Ed25519 signature over it, the boot
// verifies with its public key. A live challenge means a captured session
// cannot be replayed; only a private-key holder can pass. Unlocks the flash
// services (erase/download/transfer) — the same `unlocked` gate 0x27 used.
const auth_request_challenge = u8(0x01)
const auth_send_proof = u8(0x02)

fn (mut p Prog) authentication(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x29, nrc_incorrect_length)
	}
	if !p.in_programming_session() {
		return negative(resp, 0x29, nrc_conditions_not_correct)
	}
	sub := unsafe { req[1] }
	match sub {
		auth_request_challenge {
			// no rng / no key baked -> cannot authenticate (fail-closed)
			if p.rng == unsafe { nil } || key_is_zero(p.session_key) {
				return negative(resp, 0x29, nrc_conditions_not_correct)
			}
			if !p.rng(&p.challenge[0], 32) {
				return negative(resp, 0x29, nrc_conditions_not_correct)
			}
			p.challenge_valid = true
			unsafe {
				resp[0] = 0x69
				resp[1] = auth_request_challenge
			}
			for i in 0 .. 32 {
				unsafe {
					resp[2 + i] = p.challenge[i]
				}
			}
			return 34
		}
		auth_send_proof {
			if !p.challenge_valid {
				return negative(resp, 0x29, nrc_request_sequence_error)
			}
			if req_len < 2 + 64 {
				return negative(resp, 0x29, nrc_incorrect_length)
			}
			mut sig := [64]u8{}
			for i in 0 .. 64 {
				sig[i] = unsafe { req[2 + i] }
			}
			p.challenge_valid = false // one-shot: a fresh challenge per attempt
			// verify the signature over the challenge (no-alloc streaming verify)
			mut v := bcrypto.verify_start(p.session_key, sig)
			v.update(&p.challenge[0], 32)
			if !v.finish() {
				return negative(resp, 0x29, nrc_invalid_key)
			}
			p.unlocked = true
			unsafe {
				resp[0] = 0x69
				resp[1] = auth_send_proof
			}
			return 2
		}
		else {
			return negative(resp, 0x29, nrc_request_out_of_range)
		}
	}
}

// 0x31 RoutineControl (start only): erase (params addr+size) and check-image.
fn (mut p Prog) routine_control(req &u8, req_len int, resp &u8) int {
	if req_len < 4 {
		return negative(resp, 0x31, nrc_incorrect_length)
	}
	sub := unsafe { req[1] }
	rid := unsafe { (u16(req[2]) << 8) | u16(req[3]) }
	if sub != 0x01 {
		return negative(resp, 0x31, nrc_request_out_of_range)
	}
	if !p.in_programming_session() || p.write_locked() {
		return negative(resp, 0x31, nrc_security_access_denied)
	}
	match rid {
		routine_erase {
			if req_len < 12 {
				return negative(resp, 0x31, nrc_incorrect_length)
			}
			addr := unsafe { (u32(req[4]) << 24) | (u32(req[5]) << 16) | (u32(req[6]) << 8) | u32(req[7]) }
			size := unsafe { (u32(req[8]) << 24) | (u32(req[9]) << 16) | (u32(req[10]) << 8) | u32(req[11]) }
			// REQ-BOOT-008: the app window is the ONLY erasable region — the
			// bootloader's own storage is simply outside it.
			if !p.region_ok(addr, size) {
				return negative(resp, 0x31, nrc_request_out_of_range)
			}
			if !p.flash.erase(p.flash.ctx, addr, size) {
				return negative(resp, 0x31, nrc_general_programming_failure)
			}
			p.erased = true
			p.downloading = false
			return routine_rsp(resp, rid, 0x00)
		}
		routine_check {
			// full-image verification, then — only on success — the valid mark
			// (REQ-BOOT-005/007: mark is the LAST write, its own flash word).
			if p.downloading {
				return negative(resp, 0x31, nrc_request_sequence_error)
			}
			if !p.check_and_mark() {
				return routine_rsp(resp, rid, 0x01) // routine ran; verdict: failed
			}
			return routine_rsp(resp, rid, 0x00)
		}
		else {
			return negative(resp, 0x31, nrc_request_out_of_range)
		}
	}
}

// 0x34 RequestDownload: fmt 0x00, addrAndLengthFormat 0x44 (4-byte addr, 4-byte size).
fn (mut p Prog) request_download(req &u8, req_len int, resp &u8) int {
	if req_len < 11 {
		return negative(resp, 0x34, nrc_incorrect_length)
	}
	if !p.in_programming_session() || p.write_locked() {
		return negative(resp, 0x34, nrc_security_access_denied)
	}
	if !p.erased {
		return negative(resp, 0x34, nrc_request_sequence_error)
	}
	// a STALE valid mark must not survive into a new download: if the erase left
	// 'VALD' in word1 (an erase that didn't cover the mark word, or a permissive
	// backend), a later failed check_and_mark would leave the old mark and reset
	// would boot the new UNSIGNED image (check_image trusts the mark, not the
	// signature). Require the mark word blanked first — the app-sector erase that
	// programming the header needs already does this on real flash (REQ-BOOT-011).
	mut mk := [4]u8{}
	if !p.flash.read(p.flash.ctx, p.app_base + 32, &mk[0], 4) {
		return negative(resp, 0x34, nrc_general_programming_failure)
	}
	if mk[0] == u8(valid_mark) && mk[1] == u8(valid_mark >> 8) && mk[2] == u8(valid_mark >> 16)
		&& mk[3] == u8(valid_mark >> 24) {
		return negative(resp, 0x34, nrc_conditions_not_correct) // erase the mark word first
	}
	if unsafe { req[1] } != 0x00 || unsafe { req[2] } != 0x44 {
		return negative(resp, 0x34, nrc_request_out_of_range)
	}
	addr := unsafe { (u32(req[3]) << 24) | (u32(req[4]) << 16) | (u32(req[5]) << 8) | u32(req[6]) }
	size := unsafe { (u32(req[7]) << 24) | (u32(req[8]) << 16) | (u32(req[9]) << 8) | u32(req[10]) }
	if !p.region_ok(addr, size) || addr % prog_word != 0 {
		return negative(resp, 0x34, nrc_request_out_of_range)
	}
	p.downloading = true
	p.dl_addr = addr
	p.dl_end = addr + size
	p.next_block = 1
	p.stage_len = 0
	// 0x74: lengthFormat 0x20 (2-byte), maxNumberOfBlockLength = data + the
	// 2 service bytes of a 0x36 request.
	mb := u16(max_block_data + 2)
	unsafe {
		resp[0] = 0x74
		resp[1] = 0x20
		resp[2] = u8(mb >> 8)
		resp[3] = u8(mb)
	}
	return 4
}

// program_stage writes the staged prog_word, EXCEPT the valid-mark word (the
// second flash word, at app_base + 32): that word is the BOOT's to write, and
// only after the signature verifies (check_and_mark). A wire-supplied VALD is
// dropped — otherwise an authenticated tester could transfer a pre-marked
// (--valid / CRC-correct) UNSIGNED image and decide() would boot it at reset
// without any signature check (REQ-BOOT-011). The word stays erased for
// check_and_mark; it is neither CRC-covered (word0_crc is over 0..27) nor
// signed (the signature covers header[0..32]), so skipping it changes nothing
// for a legitimate signed image.
fn (mut p Prog) program_stage() bool {
	if p.dl_addr == p.app_base + 32 {
		p.dl_addr += prog_word // skip the valid-mark word; leave it erased
		p.stage_len = 0
		return true
	}
	if !p.flash.program(p.flash.ctx, p.dl_addr, &p.stage[0], prog_word) {
		return false
	}
	p.dl_addr += prog_word
	p.stage_len = 0
	return true
}

// 0x36 TransferData: [sid, blockCounter, data...] — stage and program in
// prog_word units.
fn (mut p Prog) transfer_data(req &u8, req_len int, resp &u8) int {
	if !p.downloading {
		return negative(resp, 0x36, nrc_request_sequence_error)
	}
	if req_len < 2 {
		return negative(resp, 0x36, nrc_incorrect_length)
	}
	blk := unsafe { req[1] }
	if blk != p.next_block {
		return negative(resp, 0x36, nrc_wrong_block_sequence)
	}
	n := u32(req_len - 2)
	if n == 0 || n > max_block_data {
		return negative(resp, 0x36, nrc_incorrect_length)
	}
	if u64(p.dl_addr) + u64(p.stage_len) + u64(n) > u64(p.dl_end) {
		return negative(resp, 0x36, nrc_request_out_of_range)
	}
	for i in u32(0) .. n {
		p.stage[p.stage_len] = unsafe { req[2 + i] }
		p.stage_len++
		if p.stage_len == prog_word {
			if !p.program_stage() {
				return negative(resp, 0x36, nrc_general_programming_failure)
			}
		}
	}
	p.next_block++
	unsafe {
		resp[0] = 0x76
		resp[1] = blk
	}
	return 2
}

// 0x37 RequestTransferExit: flush the staged tail (0xFF padding — erased-state
// bytes, so a re-check of untouched space stays true).
fn (mut p Prog) transfer_exit(req &u8, req_len int, resp &u8) int {
	if !p.downloading {
		return negative(resp, 0x37, nrc_request_sequence_error)
	}
	if p.stage_len > 0 {
		for i in p.stage_len .. prog_word {
			p.stage[i] = 0xFF
		}
		if !p.program_stage() {
			return negative(resp, 0x37, nrc_general_programming_failure)
		}
	}
	p.downloading = false
	unsafe {
		resp[0] = 0x77
	}
	return 1
}

// 0x11 EcuReset: positive response, then the owner loop performs the reset
// (reset_pending) — never reset with the response still unsent.
fn (mut p Prog) ecu_reset(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x11, nrc_incorrect_length)
	}
	sub := unsafe { req[1] }
	p.reset_pending = true
	if sub & 0x80 != 0 {
		return 0
	}
	unsafe {
		resp[0] = 0x51
		resp[1] = sub & 0x7F
	}
	return 2
}

// key_is_zero reports whether a trust anchor is unset (all-zero) — the gate it
// guards is then disabled. A real boot bakes non-zero keys and always verifies.
fn key_is_zero(k [32]u8) bool {
	for b in k {
		if b != 0 {
			return false
		}
	}
	return true
}

// check_and_mark: read back the header + image through the flash hooks, verify,
// and program the valid-mark word (word 1 of the header) on success.
fn (mut p Prog) check_and_mark() bool {
	mut hdr := [64]u8{}
	if !p.flash.read(p.flash.ctx, p.app_base, &hdr[0], 64) {
		return false
	}
	h := parse_header(&hdr[0])
	// header word 0 must be self-consistent BEFORE we trust image_len
	if h.magic != magic || h.hdr_ver != hdr_ver || h.hdr_size != hdr_size {
		return false
	}
	// a signed image also has a 64-byte signature after the image; require the
	// whole extent (header ‖ image ‖ sig) to sit inside the app window.
	signed := !key_is_zero(p.image_key)
	sig_span := if signed { u32(64) } else { u32(0) }
	if h.image_len == 0 || h.image_len > max_image_len
		|| !p.region_ok(p.app_base, hdr_size + h.image_len + sig_span) {
		return false
	}
	if crc32(&hdr[0], 28) != h.word0_crc {
		return false
	}
	// One image pass feeds BOTH the CRC (fast bit-rot pre-check) and the
	// Ed25519 verify (authenticity). The signed region is header[0..32] ‖ image.
	mut ver := bcrypto.Verifier{}
	if signed {
		mut sig := [64]u8{}
		if !p.flash.read(p.flash.ctx, p.app_base + hdr_size + h.image_len, &sig[0], 64) {
			return false
		}
		ver = bcrypto.verify_start(p.image_key, sig)
		ver.update(&hdr[0], 32)
	}
	mut crc := u32(0xFFFF_FFFF)
	mut off := u32(0)
	mut buf := [64]u8{}
	for off < h.image_len {
		mut n := h.image_len - off
		if n > 64 {
			n = 64
		}
		if !p.flash.read(p.flash.ctx, p.app_base + hdr_size + off, &buf[0], n) {
			return false
		}
		crc = crc32_update(crc, &buf[0], n)
		if signed {
			ver.update(&buf[0], int(n))
		}
		off += n
	}
	if (crc ^ 0xFFFF_FFFF) != h.image_crc {
		return false
	}
	// authenticity is the last gate before the mark: an unsigned or
	// wrongly-signed image is refused (no mark, decide() -> stay_boot).
	if signed && !ver.finish() {
		return false
	}
	// the LAST write: the valid mark, alone in its 32-byte flash word
	mut mark := [32]u8{}
	for i in 0 .. 32 {
		mark[i] = 0xFF
	}
	mark[0] = u8(valid_mark)
	mark[1] = u8(valid_mark >> 8)
	mark[2] = u8(valid_mark >> 16)
	mark[3] = u8(valid_mark >> 24)
	return p.flash.program(p.flash.ctx, p.app_base + 32, &mark[0], prog_word)
}

// crc32_update: the streaming form of crc32 (caller owns init/final XOR).
pub fn crc32_update(crc_in u32, data &u8, len u32) u32 {
	mut crc := crc_in
	for i in u32(0) .. len {
		crc ^= u32(unsafe { data[i] })
		for _ in 0 .. 8 {
			mask := -(crc & 1)
			crc = (crc >> 1) ^ (u32(0xEDB8_8320) & mask)
		}
	}
	return crc
}

fn routine_rsp(resp &u8, rid u16, result u8) int {
	unsafe {
		resp[0] = 0x71
		resp[1] = 0x01
		resp[2] = u8(rid >> 8)
		resp[3] = u8(rid)
		resp[4] = result
	}
	return 5
}

fn negative(resp &u8, sid u8, nrc u8) int {
	unsafe {
		resp[0] = 0x7F
		resp[1] = sid
		resp[2] = nrc
	}
	return 3
}
