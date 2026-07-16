module boot

// @verifies REQ-BOOT-001, REQ-BOOT-002

// CRC-32 (IEEE 802.3): the canonical check vector.
fn test_crc32_vector() {
	data := [u8(`1`), `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`]
	assert crc32(&data[0], 9) == u32(0xCBF43926)
	// empty input -> the identity
	assert crc32(&data[0], 0) == u32(0)
}

fn build_image(image_len u32, valid bool, corrupt_image bool, corrupt_hdr bool) []u8 {
	mut img := []u8{len: int(hdr_size) + int(image_len)}
	for i in 0 .. int(image_len) {
		img[int(hdr_size) + i] = u8(i * 7 + 3)
	}
	crc := crc32(unsafe { &img[int(hdr_size)] }, image_len)
	mut hdr := [64]u8{}
	make_header(mut hdr, image_len, crc, 0x0001_0002, valid)
	for i in 0 .. 64 {
		img[i] = hdr[i]
	}
	if corrupt_image {
		img[int(hdr_size) + 5] ^= 0x40
	}
	if corrupt_hdr {
		img[9] ^= 0x01 // image_len byte -> word0_crc mismatch
	}
	return img
}

fn test_valid_image_checks_out() {
	img := build_image(1000, true, false, false)
	assert check_header(&img[0])
	assert check_image(&img[0])
	h := parse_header(&img[0])
	assert h.image_len == 1000
	assert h.sw_version == 0x0001_0002
}

// check_image_slot bounds the CRC walk to the app slot: a header can keep its
// valid mark while a torn erase / bit rot leaves image_len pointing past the
// region (mark and length live in different flash words). The unbounded walk
// would read off the end of flash BEFORE CAN is up — check_image_slot rejects
// it first (REQ-BOOT-002).
fn test_slot_bound_rejects_oversized_length() {
	img := build_image(1000, true, false, false)
	// generous slot: header + image fit, verdict matches the plain check
	assert check_image_slot(&img[0], hdr_size + 1000)
	assert check_image_slot(&img[0], 0x0010_0000)
	// slot smaller than hdr_size + image_len: reject before the CRC walk, even
	// though check_image (unbounded) would have trusted the marked header
	assert !check_image_slot(&img[0], hdr_size + 999)
	assert !check_image_slot(&img[0], 512)
	assert check_image(&img[0]) // the image itself is genuinely valid
}

// The valid mark is the LAST thing written: without it a perfectly transferred
// image must still not boot (REQ-BOOT-002/005 — a torn update looks exactly
// like this).
fn test_unmarked_image_does_not_boot() {
	img := build_image(1000, false, false, false)
	assert !check_header(unsafe { &img[0] })
	assert !check_image(&img[0])
	assert decide(false, check_image(&img[0])) == .stay_boot
}

fn test_corrupt_image_detected() {
	img := build_image(1000, true, true, false)
	assert check_header(&img[0]) // header itself is fine...
	assert !check_image(&img[0]) // ...but the image CRC says no
}

fn test_corrupt_header_detected() {
	img := build_image(1000, true, false, true)
	assert !check_header(unsafe { &img[0] })
	assert !check_image(&img[0])
}

// Erased flash (all 0xFF) must fail FAST on the length sanity bound, not walk
// a 4 GB CRC (REQ-BOOT-002 on a factory-fresh part).
fn test_erased_flash_is_invalid() {
	mut img := []u8{len: 64, init: 0xFF}
	assert !check_header(unsafe { &img[0] })
}

// The boot decision truth table (REQ-BOOT-001).
fn test_decide() {
	assert decide(false, true) == .run_app
	assert decide(true, true) == .stay_boot // pending request wins over a valid app
	assert decide(false, false) == .stay_boot
	assert decide(true, false) == .stay_boot
}
