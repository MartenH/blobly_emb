module main

import os
import driver.can
import gen
import osal.vrt as _ // V's builtin hooks on target

// entry is the image's entry point: crt0.S jumps to it by its exported C name (BOARD_ENTRY)
// after bss/data init. Not V's `fn main`, which V3 wraps in a hosted C main (VEXE env setup,
// _vinit); the image enters by a name it owns, never by V's mangling of `main`.
@[export: 'blob_entry']
fn entry() {
	if0 := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	if1 := if os.args.len > 2 { os.args[2] } else { 'vcan1' }
	if2 := if os.args.len > 3 { os.args[3] } else { 'vcan2' }
	println('system_full gateway: ${if0} (compute), ${if1} (edge), ${if2} (body)')
	mut c0 := can.Channel{}
	if !c0.open(if0, gen.can0_fd) {
		eprintln('failed to open ${if0} — is vcan up?')
		return
	}
	mut c1 := can.Channel{}
	if !c1.open(if1, gen.can1_fd) {
		eprintln('failed to open ${if1} — is vcan up?')
		return
	}
	mut c2 := can.Channel{}
	if !c2.open(if2, gen.can2_fd) {
		eprintln('failed to open ${if2} — is vcan up?')
		return
	}
	gen.run(c0, c1, c2)
}

// main is never called on target (crt0 enters at `entry`); V requires one in module main
fn main() {
	entry()
}
