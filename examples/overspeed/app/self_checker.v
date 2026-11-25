module app

import ports

// SelfChecker runs the SelfCheck routine (RoutineControl 0x31 0x0201, ecu.toml; docs/diagnostics.md
// §3.1): a start with option N runs N steps of 100 ms — 2N dispatches of its 50 ms handler — and is
// done with the dispatches it counted (u16 big-endian); option 0 is refused (requestOutOfRange). A
// stop the server asks for (a timeout, or the session ending under it) ends it, answered stopped.
pub struct SelfChecker {
pub mut:
	left  u32 // dispatches still to run (0 = idle)
	count u16 // dispatches run
}

pub fn (mut fb SelfChecker) on_50ms(inp ports.SelfCheckerIn, mut out ports.SelfCheckerOut) {
	match inp.self_check_request.op {
		.start {
			steps := u32(inp.self_check_request.option[0])
			if steps == 0 {
				out.self_check_result.state = .refused
				out.self_check_result.nrc = 0x31
				return
			}
			fb.left = 2 * steps
			fb.count = 0
		}
		.stop {
			fb.left = 0
			out.self_check_result.state = .stopped
			fb.put_count(mut out)
			return
		}
		else {}
	}
	if fb.left == 0 {
		return // idle: nothing new, the last report stands
	}
	fb.count++
	fb.left--
	out.self_check_result.state = if fb.left == 0 { .done } else { .running }
	fb.put_count(mut out)
}

fn (fb &SelfChecker) put_count(mut out ports.SelfCheckerOut) {
	out.self_check_result.record[0] = u8(fb.count >> 8)
	out.self_check_result.record[1] = u8(fb.count)
}
