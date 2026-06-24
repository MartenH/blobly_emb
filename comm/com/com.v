module com

// COM: pack/unpack typed signals into raw frame payloads.
// Operates on fixed [64]u8 buffers — no slices, no heap.
// (Little-endian for now; endianness/bit-packing become config-driven later.)

pub fn get_u16(data [64]u8, offset int) u16 {
	return u16(data[offset]) | (u16(data[offset + 1]) << 8)
}

pub fn set_u16(mut data [64]u8, offset int, val u16) {
	data[offset] = u8(val)
	data[offset + 1] = u8(val >> 8)
}
