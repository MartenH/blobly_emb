// mkimage — BUILD-TIME tool: wrap a raw application .bin in the blobly boot
// header (docs/bootloader.md). The output is what the host flasher transfers
// and the boot manager verifies; the valid mark is set ONLY with --valid (a
// factory image programmed whole over SWD — the field path leaves it unset
// and the ECU's check routine marks after verifying).
//
//   v run tools/mkimage <app.bin> <out.img> <sw_version> [--valid] [--pad-vectors] [--sign <seed>]
//
// --pad-vectors: pad 0xFF between the header and the app so the app's vector
// table lands at +0x400 from the region base (Cortex-M VTOR alignment — the
// boards bootmap.h APP_VECTORS contract). The CRC covers the pad.
//
// --sign <seedfile>: append a 64-byte Ed25519 signature over header[0..32] ‖
// image (REQ-BOOT-011). The seed file is 64 hex chars (a 32-byte seed); a real
// signer keeps it off every machine (examples/keys/README.md). --sign is
// incompatible with --valid: a signed image is authenticated by the boot's
// verify-before-mark, so pre-marking it (--valid) would sidestep the check.
module main

import os
import boot
import bcrypto

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
	sign_seed := opt(args, '--sign')
	if 'sign' in flags(args) && sign_seed == '' {
		panic('mkimage: --sign needs a seed file argument (e.g. --sign examples/keys/dev.seed)')
	}
	if valid && sign_seed != '' {
		panic('mkimage: --valid and --sign are mutually exclusive (a signed image is ' +
			'authenticated by the boot before it marks valid; --valid would skip that)')
	}

	mut image := raw.clone()
	if pad_vectors {
		mut padded := []u8{len: vectors_off - int(boot.hdr_size), init: 0xFF}
		padded << raw
		image = padded.clone()
	}

	crc := boot.crc32(unsafe { &image[0] }, u32(image.len))
	mut hdr := [64]u8{}
	boot.make_header(mut hdr, u32(image.len), crc, sw_version, valid)

	mut out := []u8{cap: 64 + image.len + 64}
	for b in hdr {
		out << b
	}
	out << image

	mut signed := false
	if sign_seed != '' {
		seed := read_seed(sign_seed)
		// the signed region is header word0 (bytes 0..32) ‖ image — the same
		// bytes the boot streams into verify. The valid-mark word (32..63) is
		// excluded; the boot writes it after the signature checks out.
		mut msg := []u8{cap: 32 + image.len}
		for i in 0 .. 32 {
			msg << hdr[i]
		}
		msg << image
		sig := bcrypto.sign(seed, msg)
		for i in 0 .. 64 {
			out << sig[i]
		}
		signed = true
	}

	os.write_file_array(args[2], out) or { panic('mkimage: write ${args[2]}: ${err}') }
	eprintln('mkimage: ${args[2]}: ${image.len} image bytes' +
		'${if pad_vectors { ' (vectors @ +0x400)' } else { '' }}, crc 0x${crc.hex()}, ' +
		'sw_version ${sw_version}${if valid { ', VALID (factory)' } else { '' }}' +
		'${if signed { ', SIGNED (ed25519)' } else { '' }}')
}

// read_seed parses a 64-hex-char seed file (whitespace ignored).
fn read_seed(path string) [32]u8 {
	txt := os.read_file(path) or { panic('mkimage: read seed ${path}: ${err}') }
	hexs := txt.trim_space()
	if hexs.len != 64 {
		panic('mkimage: seed ${path} must be 64 hex chars (32 bytes), got ${hexs.len}')
	}
	mut s := [32]u8{}
	for i in 0 .. 32 {
		s[i] = u8(('0x' + hexs[i * 2..i * 2 + 2]).u8())
	}
	return s
}

// opt returns the value following flag (e.g. --sign <value>), or '' if absent.
fn opt(args []string, flag string) string {
	for i in 0 .. args.len - 1 {
		if args[i] == flag {
			return args[i + 1]
		}
	}
	return ''
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
