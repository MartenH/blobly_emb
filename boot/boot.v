module boot

// Bootloader core: the image-header contract and the reset-time boot decision.
// No-alloc, host-testable, target-agnostic — the boards layer supplies flash
// geometry and the cells; this module supplies the logic (docs/bootloader.md,
// requirements/boot.toml).
//
// Header layout (v1, 64 bytes = two 32-byte flash words on STM32H7 — the valid
// mark MUST be its own program word so it can be written LAST without touching
// the rest, REQ-BOOT-005/007):
//
//   word 0 (offsets 0..31)                     word 1 (offsets 32..63)
//     0  magic      u32 'BLBT'                   32  valid_mark u32 'VALD'
//     4  hdr_ver    u16 = 1                      36..63 erased / reserved
//     6  reserved   u16
//     8  image_len  u32  bytes after the header
//    12  image_crc  u32  CRC-32 over the image bytes
//    16  sw_version u32
//    20  hdr_size   u32 = 64
//    24  reserved   u32
//    28  word0_crc  u32  CRC-32 over bytes 0..27 (header self-check)

pub const magic = u32(0x54424C42) // 'BLBT' little-endian
pub const valid_mark = u32(0x444C4156) // 'VALD' little-endian
pub const hdr_size = u32(64)
pub const hdr_ver = u16(1)

// max_image_len rejects absurd lengths before any CRC walk — a fresh (erased,
// all-0xFF) header must fail fast, not send the CRC across 4 GB of bus faults.
pub const max_image_len = u32(0x0100_0000) // 16 MB: beyond any target flash

pub struct Header {
pub mut:
	magic      u32
	hdr_ver    u16
	image_len  u32
	image_crc  u32
	sw_version u32
	hdr_size   u32
	word0_crc  u32
	valid      u32
}

// crc32 — IEEE 802.3 (reflected 0xEDB88320), bitwise: no table, no alloc. The
// boot-time cost over a full image is tens of ms; trade a rodata table for it
// later if the boot budget ever demands.
pub fn crc32(data &u8, len u32) u32 {
	mut crc := u32(0xFFFF_FFFF)
	for i in u32(0) .. len {
		crc ^= u32(unsafe { data[i] })
		for _ in 0 .. 8 {
			mask := -(crc & 1)
			crc = (crc >> 1) ^ (u32(0xEDB8_8320) & mask)
		}
	}
	return crc ^ 0xFFFF_FFFF
}

fn rd32(p &u8, off u32) u32 {
	unsafe {
		return u32(p[off]) | (u32(p[off + 1]) << 8) | (u32(p[off + 2]) << 16) | (u32(p[off + 3]) << 24)
	}
}

fn rd16(p &u8, off u32) u16 {
	unsafe {
		return u16(p[off]) | (u16(p[off + 1]) << 8)
	}
}

// parse_header decodes the 64-byte header block (no validation beyond bounds —
// see check_header/check_image for the verdicts).
pub fn parse_header(p &u8) Header {
	return Header{
		magic:      rd32(p, 0)
		hdr_ver:    rd16(p, 4)
		image_len:  rd32(p, 8)
		image_crc:  rd32(p, 12)
		sw_version: rd32(p, 16)
		hdr_size:   rd32(p, 20)
		word0_crc:  rd32(p, 28)
		valid:      rd32(p, 32)
	}
}

// check_header: is word 0 a self-consistent v1 header with the valid mark set?
// Cheap (no image walk) — the fast half of the boot decision.
pub fn check_header(p &u8) bool {
	h := parse_header(p)
	if h.magic != magic || h.hdr_ver != hdr_ver || h.hdr_size != hdr_size {
		return false
	}
	if h.image_len == 0 || h.image_len > max_image_len {
		return false
	}
	if crc32(p, 28) != h.word0_crc {
		return false
	}
	return h.valid == valid_mark
}

// check_image: the full verdict — header self-consistent AND the image bytes
// (starting at hdr_size, image_len long) match image_crc. `img` points at the
// START of the header; the caller guarantees hdr_size + image_len readable
// (memory-mapped flash on target, a buffer on host).
pub fn check_image(img &u8) bool {
	if !check_header(img) {
		return false
	}
	h := parse_header(img)
	return unsafe { crc32(&u8(&img[hdr_size]), h.image_len) } == h.image_crc
}

// The boot decision (REQ-BOOT-001/002): stay in the bootloader when programming
// is requested or no valid application exists; otherwise run the app. Pure —
// the caller reads the request cell and the flash, then acts on the verdict.
pub enum Action {
	run_app
	stay_boot
}

pub fn decide(prog_requested bool, app_valid bool) Action {
	if prog_requested || !app_valid {
		return .stay_boot
	}
	return .run_app
}

// make_header builds header word 0 + valid mark for a build/host tool or the
// check routine: fills the fixed fields and both CRCs into out[0..63]. The
// valid mark is included ONLY when `valid` is set — the programming session
// writes word 0 with valid=false during transfer and marks word 1 after the
// full-image check passes.
pub fn make_header(mut out [64]u8, image_len u32, image_crc u32, sw_version u32, valid bool) {
	for i in 0 .. 64 {
		out[i] = 0xFF
	}
	wr32(mut out, 0, magic)
	wr16(mut out, 4, hdr_ver)
	wr16(mut out, 6, 0)
	wr32(mut out, 8, image_len)
	wr32(mut out, 12, image_crc)
	wr32(mut out, 16, sw_version)
	wr32(mut out, 20, hdr_size)
	wr32(mut out, 24, 0)
	wr32(mut out, 28, crc32(&out[0], 28))
	if valid {
		wr32(mut out, 32, valid_mark)
	}
}

fn wr32(mut out [64]u8, off int, v u32) {
	out[off] = u8(v)
	out[off + 1] = u8(v >> 8)
	out[off + 2] = u8(v >> 16)
	out[off + 3] = u8(v >> 24)
}

fn wr16(mut out [64]u8, off int, v u16) {
	out[off] = u8(v)
	out[off + 1] = u8(v >> 8)
}
