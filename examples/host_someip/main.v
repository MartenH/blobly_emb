module main

// Platform entry, P1-gen rung: no sockets yet — run() dispatches the app
// partition; the generated eth codec (gen.benchtelem_pack + the someip_*
// consts) is compiled and ready for the UDP tx rung (docs/someip.md).

import gen

fn main() {
	println('host_someip: eth0 SOME/IP service 0x${gen.someip_service:04X} v${gen.someip_version} — codegen rung, no wire yet')
	gen.run()
}
