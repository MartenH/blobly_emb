// examples/h735_someip — SOME/IP events off real silicon (docs/someip.md, the
// NetX bench rung). The wire is IDENTICAL to examples/host_someip — service
// 0x0100, event 0x8001, the BenchTelem derived layout (load u8@0, ticks
// u32@1 LE, wraps u16@5) + the 2-byte E2E trailer (ctr@7, crc@8, data_id
// 0x21) — so the same listener + blobly_net oracle verify both. Hand-wired
// per the h735_doip precedent: comm/someip + comm/e2e are tested V, the
// packing mirrors the generated bench_telem_pack; full loom2v target
// integration is its own rung.
//
// Bench: events unicast to the bench listener (192.168.0.190:30491) every 100 ms — listen on
// any subnet host with the host_someip byte-verifier.
import comm.someip
import comm.e2e

fn C.board_clock_init()
fn C.glue_kernel_enter()
fn C.net_udp_send(ip &u8, port u16, buf &u8, len int) int
fn C.net_sleep_ms(ms int)

const service = u16(0x0100)
const event_id = u16(0x8001)
const iface_ver = u8(1)
const payload_len = 9 // 7-byte layout + the E2E trailer
const e2e_id = u16(0x21)
const peer_port = u16(30491)

__global g_e2e e2e.TxState

@[export: 'blobly_someip_run']
fn blobly_someip_run() {
	peer := [u8(192), 168, 0, 190]! // the bench listener host ([someip].peer)
	mut dgram := [80]u8{} // someip.header_len + the payload
	mut ticks := u32(0)
	for {
		ticks++
		mut pay := [64]u8{}
		// the BenchTelem derived layout, byte for byte (docs/someip.md)
		pay[0] = u8(ticks % 100)
		pay[1] = u8(ticks)
		pay[2] = u8(ticks >> 8)
		pay[3] = u8(ticks >> 16)
		pay[4] = u8(ticks >> 24)
		wraps := u16(ticks >> 16)
		pay[5] = u8(wraps)
		pay[6] = u8(wraps >> 8)
		// save/protect/send/rollback — the generated eth bridge's pattern: an
		// unsent event must not advance the counter (false loss at the peer)
		e2e_save := g_e2e
		g_e2e.protect(&pay[0], payload_len, e2e_id, 8, 7) // crc@8, ctr@7
		h := someip.notification(service, event_id, iface_ver, payload_len)
		n := someip.encode(h, &dgram[0])
		for i in 0 .. payload_len {
			dgram[n + i] = pay[i]
		}
		if C.net_udp_send(&peer[0], peer_port, &dgram[0], n + payload_len) != 0 {
			g_e2e = e2e_save
		}
		C.net_sleep_ms(100)
	}
}

fn main() {
	C.board_clock_init()
	C.glue_kernel_enter() // -> ThreadX -> app thread -> blobly_someip_run
}
