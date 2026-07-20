module main

// Platform entry, UDP tx rung (docs/someip.md): open the node's static UDP
// endpoint on loopback and hand off to gen.run — the generated eth comm
// thread packs the derived layouts, wraps them in SOME/IP notification
// headers, and sends them to the configured peer (someip_peer_ip/port).
// Listen on the peer side to watch the events:  nc -ul 30491 | xxd
import gen
import driver.eth

fn main() {
	println('host_someip: eth0 SOME/IP service 0x${gen.someip_service:04X} v${gen.someip_version} — events to peer :${gen.someip_peer_port}')
	mut sock := eth.Socket{}
	if !sock.open('127.0.0.1', gen.someip_port) {
		eprintln('failed to bind 127.0.0.1:${gen.someip_port}')
		return
	}
	gen.run(sock)
}
