module main

// The serve loop of a node with no DoIP: the bus is the boot's one transport, so the stay path is a
// bare superloop — no kernel, the main stack.

fn C.board_timebase_init()

fn serve() {
	C.board_timebase_init() // board_now_us reads DWT: without it `now` is frozen and nothing expires
	serve_loop()
}

fn net_serves() bool {
	return false
}

fn net_pass(now u64) {}

fn net_drain() {}
