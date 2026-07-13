// mkimage — BUILD-TIME tool: wrap a raw application .bin in the blobly boot
// header (docs/bootloader.md). The output is what the host flasher transfers
// and the boot manager verifies; the valid mark is set ONLY with --valid (a
// factory image programmed whole over SWD — the field path leaves it unset
// and the ECU's check routine marks after verifying).
//
//   v run tools/mkimage <app.bin> <out.img> <sw_version> [--valid] [--pad-vectors]
//
// --pad-vectors: pad 0xFF between the header and the app so the app's vector
// table lands at +0x400 from the region base (Cortex-M VTOR alignment — the
// boards bootmap.h APP_VECTORS contract). The CRC covers the pad.
module main

import os
import boot

const vectors_off = 0x400 // must match the boards' APP_VECTORS offset

fn main() {
	args := os.args
	if args.len < 4 {
		eprintln('usage: mkimage <app.bin> <out.img> <sw_version> [--valid] [--pad-vectors]')
		exit(2)
	}
	raw := os.read_bytes(args[1]) or { panic('mkimage: read ${args[1]}: ${err}') }
	if raw.len == 0 {
		panic('mkimage: ${args[1]} is empty')
	}
	sw_version := u32(args[3].u64())
	valid := 'valid' in flags(args)
	pad_vectors := 'pad-vectors' in flags(args)

	mut image := raw.clone()
	if pad_vectors {
		mut padded := []u8{len: vectors_off - int(boot.hdr_size), init: 0xFF}
		padded << raw
		image = padded.clone()
	}

	crc := boot.crc32(unsafe { &image[0] }, u32(image.len))
	mut hdr := [64]u8{}
	boot.make_header(mut hdr, u32(image.len), crc, sw_version, valid)

	mut out := []u8{cap: 64 + image.len}
	for b in hdr {
		out << b
	}
	out << image
	os.write_file_array(args[2], out) or { panic('mkimage: write ${args[2]}: ${err}') }
	eprintln('mkimage: ${args[2]}: ${image.len} image bytes' +
		'${if pad_vectors { ' (vectors @ +0x400)' } else { '' }}, crc 0x${crc.hex()}, ' +
		'sw_version ${sw_version}${if valid { ', VALID (factory)' } else { '' }}')
}

fn flags(args []string) []string {
	mut fl := []string{}
	for a in args {
		if a.starts_with('--') {
			fl << a.trim_string_left('--')
		}
	}
	return fl
}
