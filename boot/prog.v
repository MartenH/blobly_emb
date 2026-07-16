module boot

// The programming session — UDS services 0x27/0x31/0x34/0x36/0x37/0x11 layered
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
	// security (REQ-BOOT-011 seam): a trivial seed/key pair for now — the algo
	// is a hook to replace, the SEQUENCE enforcement is what this layer owns.
	unlocked  bool
	seed_sent bool
	seed      u32 // set by init() — 'BLOB' placeholder until the real scheme (P5)
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
		0x27 { return p.security_access(req, req_len, resp) }
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
	p.seed = 0x424C4F42 // 'BLOB' — placeholder until the real scheme (P5)
	p.srv.session = 0x01 // default diagnostic session
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
		p.seed_sent = false
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

// region_ok: [addr, addr+size) inside the app window, non-empty, no overflow.
fn (p Prog) region_ok(addr u32, size u32) bool {
	if size == 0 {
		return false
	}
	end := u64(addr) + u64(size)
	return addr >= p.app_base && end <= u64(p.app_base) + u64(p.app_size)
}

// 0x27 SecurityAccess: sub 0x01 = request seed, sub 0x02 = send key.
fn (mut p Prog) security_access(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x27, nrc_incorrect_length)
	}
	if !p.in_programming_session() {
		return negative(resp, 0x27, nrc_conditions_not_correct)
	}
	sub := unsafe { req[1] }
	match sub {
		0x01 {
			// already unlocked -> an all-zero seed by convention
			s := if p.unlocked { u32(0) } else { p.seed }
			unsafe {
				resp[0] = 0x67
				resp[1] = 0x01
				resp[2] = u8(s >> 24)
				resp[3] = u8(s >> 16)
				resp[4] = u8(s >> 8)
				resp[5] = u8(s)
			}
			p.seed_sent = true
			return 6
		}
		0x02 {
			if !p.seed_sent {
				return negative(resp, 0x27, nrc_request_sequence_error)
			}
			if req_len < 6 {
				return negative(resp, 0x27, nrc_incorrect_length)
			}
			key := unsafe { (u32(req[2]) << 24) | (u32(req[3]) << 16) | (u32(req[4]) << 8) | u32(req[5]) }
			if key != expected_key(p.seed) {
				p.seed_sent = false
				return negative(resp, 0x27, nrc_invalid_key)
			}
			p.unlocked = true
			unsafe {
				resp[0] = 0x67
				resp[1] = 0x02
			}
			return 2
		}
		else {
			return negative(resp, 0x27, nrc_request_out_of_range)
		}
	}
}

// expected_key — the placeholder algorithm both sides share until P5: key =
// seed XOR'd with the complement rotated. Deliberately trivial and deliberately
// one function: replacing it IS the P5 upgrade path.
pub fn expected_key(seed u32) u32 {
	return (seed ^ 0xA5A5_A5A5) + (seed << 3 | seed >> 29)
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
	if !p.in_programming_session() || !p.unlocked {
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
	if !p.in_programming_session() || !p.unlocked {
		return negative(resp, 0x34, nrc_security_access_denied)
	}
	if !p.erased {
		return negative(resp, 0x34, nrc_request_sequence_error)
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
			if !p.flash.program(p.flash.ctx, p.dl_addr, &p.stage[0], prog_word) {
				return negative(resp, 0x36, nrc_general_programming_failure)
			}
			p.dl_addr += prog_word
			p.stage_len = 0
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
		if !p.flash.program(p.flash.ctx, p.dl_addr, &p.stage[0], prog_word) {
			return negative(resp, 0x37, nrc_general_programming_failure)
		}
		p.dl_addr += prog_word
		p.stage_len = 0
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
	if h.image_len == 0 || h.image_len > max_image_len
		|| !p.region_ok(p.app_base, hdr_size + h.image_len) {
		return false
	}
	if crc32(&hdr[0], 28) != h.word0_crc {
		return false
	}
	// image CRC, streamed through the read hook in stage-sized chunks
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
		off += n
	}
	if (crc ^ 0xFFFF_FFFF) != h.image_crc {
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
