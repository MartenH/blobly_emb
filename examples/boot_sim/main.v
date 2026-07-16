module main

// boot_sim — the bootloader on a virtual bus (sim-first, no silicon needed).
// The SAME boot.Prog session logic the target runs, wired to SocketCAN via
// comm/isotp and backed by a FILE instead of flash. One process run = one
// power cycle: it makes the boot decision on start (like the real boot
// manager), serves the programming session, and exits on ECU reset (0x11) —
// run it again for "the next boot".
//
//   make vcan          # once: vcan0 up
//   make run           # decision + serve on vcan0 (rx 0x7B0 / tx 0x7B8)
//   ../../../blobly_net: v run cmd/flash vcan0 <image.bin>   # reflash it
//
// The flash file (bin/flash.bin) models the app region: 64 KB at 0x08020000.
// Erased-new = all 0xFF -> the first boot decides stay_boot (no valid app).
import os
import time
import boot
import comm.isotp
import driver.can

const app_base = u32(0x0802_0000)
const app_size = u32(0x0001_0000)
const req_id = u32(0x7B0)
const rsp_id = u32(0x7B8)
const flash_file = 'bin/flash.bin'

struct FileFlash {
mut:
	mem []u8
}

fn ff_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &FileFlash(ctx) }
	for i in u32(0) .. size {
		f.mem[addr - app_base + i] = 0xFF
	}
	return true
}

fn ff_program(ctx voidptr, addr u32, data &u8, len u32) bool {
	mut f := unsafe { &FileFlash(ctx) }
	for i in u32(0) .. len {
		f.mem[addr - app_base + i] = unsafe { data[i] }
	}
	return true
}

fn ff_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	f := unsafe { &FileFlash(ctx) }
	for i in u32(0) .. len {
		unsafe {
			out[i] = f.mem[addr - app_base + i]
		}
	}
	return true
}

// sim challenge source — NOT cryptographic (a demo nonce); the target uses the
// board TRNG. Enough to exercise the 0x29 challenge/response end to end.
fn sim_rng(out &u8, n int) bool {
	unsafe {
		for i in 0 .. n {
			out[i] = u8((i * 13 + 7) & 0xff)
		}
	}
	return true
}

fn main() {
	iface := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	os.mkdir_all('bin') or {}
	mut ff := &FileFlash{}
	ff.mem = if os.exists(flash_file) {
		os.read_bytes(flash_file) or { []u8{len: int(app_size), init: 0xFF} }
	} else {
		[]u8{len: int(app_size), init: 0xFF}
	}
	if ff.mem.len != int(app_size) {
		ff.mem = []u8{len: int(app_size), init: 0xFF}
	}

	// --- the boot decision, exactly the target's sequence (REQ-BOOT-001/002) ---
	app_valid := boot.check_image(unsafe { &ff.mem[0] })
	verdict := boot.decide(false, app_valid) // request cell: a process arg in the sim
	h := boot.parse_header(unsafe { &ff.mem[0] })
	if verdict == .run_app {
		println('boot_sim: app VALID (sw_version ${h.sw_version}, len ${h.image_len}) -> run_app')
		println('boot_sim: (a real boot manager jumps here; the sim serves anyway — reflash me)')
	} else {
		println('boot_sim: no valid app -> stay_boot (programming mode)')
	}

	mut p := boot.Prog{
		flash:    boot.FlashOps{
			ctx:     ff
			erase:   ff_erase
			program: ff_program
			read:    ff_read
		}
		app_base: app_base
		app_size: app_size
	}
	p.init() // seed + default session — no field defaults (the _vinit rule)
	p.image_key = [u8(0x03), 0xa1, 0x07, 0xbf, 0xf3, 0xce, 0x10, 0xbe, 0x1d, 0x70, 0xdd, 0x18, 0xe7, 0x4b, 0xc0, 0x99, 0x67, 0xe4, 0xd6, 0x30, 0x9b, 0xa5, 0x0d, 0x5f, 0x1d, 0xdc, 0x86, 0x64, 0x12, 0x55, 0x31, 0xb8]! // release key (examples/keys/mkimage.seed)
	p.session_key = [u8(0x29), 0xac, 0xba, 0xe1, 0x41, 0xbc, 0xca, 0xf0, 0xb2, 0x2e, 0x1a, 0x94, 0xd3, 0x4d, 0x0b, 0xc7, 0x36, 0x1e, 0x52, 0x6d, 0x0b, 0xfe, 0x12, 0xc8, 0x97, 0x94, 0xbc, 0x93, 0x22, 0x96, 0x6d, 0xd7]! // tester key (examples/keys/tester.seed)
	p.rng = sim_rng // 0x29 challenge source
	// identification DIDs (REQ-BOOT-009): F180 = boot version, F181 = app state
	p.srv.dids[0].id = 0xF180
	p.srv.dids[0].data[0] = 0x00
	p.srv.dids[0].data[1] = 0x01 // boot_sim v0.1
	p.srv.dids[0].len = 2
	p.srv.dids[1].id = 0xF181
	p.srv.dids[1].data[0] = if app_valid { u8(1) } else { 0 }
	p.srv.dids[1].len = 1
	p.srv.ndid = 2

	mut ch := can.Channel{}
	if !ch.open(iface, false) {
		eprintln('boot_sim: cannot open ${iface} (make vcan?)')
		exit(1)
	}
	println('boot_sim: serving UDS on ${iface} rx 0x${req_id.hex()} / tx 0x${rsp_id.hex()}')

	mut link := isotp.Link{}
	link.init_defaults()
	mut req := [isotp.max_payload]u8{}
	mut rsp := [isotp.max_payload]u8{}
	for {
		now := u64(time.sys_mono_now() / 1000)
		mut f := can.Frame{}
		for ch.recv(mut f) {
			if f.id != req_id {
				continue
			}
			mut pdu := isotp.Pdu{}
			for i in 0 .. 8 {
				pdu.data[i] = f.data[i]
			}
			link.on_frame(now, pdu)
		}
		if link.ready {
			n := link.take(&req[0])
			p.last_rx_us = now // the tester-silence clock (REQ-BOOT-013)
			rn := p.handle(&req[0], n, &rsp[0])
			if rn > 0 {
				link.send(&rsp[0], rn)
			}
		}
		p.tick(now) // S3 (REQ-BOOT-013): silence drops the session + unlock
		link.tick(now)
		mut out := isotp.Pdu{}
		for ch.tx_ready() && link.poll(now, mut out) {
			mut tf := can.Frame{
				id:  rsp_id
				len: 8
			}
			for i in 0 .. 8 {
				tf.data[i] = out.data[i]
			}
			ch.send(tf)
			out = isotp.Pdu{}
		}
		if p.reset_pending && !link.busy() {
			os.write_file_array(flash_file, ff.mem) or {
				eprintln('boot_sim: persist ${flash_file}: ${err}')
			}
			valid_now := boot.check_image(unsafe { &ff.mem[0] })
			h2 := boot.parse_header(unsafe { &ff.mem[0] })
			next := boot.decide(false, valid_now)
			println('boot_sim: ECU reset -> flash persisted; next boot would ${if next == .run_app {
				'run_app (sw_version ${h2.sw_version})'
			} else {
				'stay_boot'
			}}')
			exit(0)
		}
		time.sleep(1 * time.millisecond)
	}
}
