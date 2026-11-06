module app

// The CM4 "dynamics" co-processor FB (system_full domain satellite). It burns a bounded LCG
// window (so the CM4 shows a REAL load in the cross-core CpuLoad frame) and publishes the result
// as TorqueEstimate — a CROSS-CORE signal the CM7 control loop reads. It also reads three signals
// the CM7 hands DOWN to it — DynCmd (a protected bus frame, with its receive status), HostLedLevel
// (a bus signal the CM7 reads too, held to the DynLedCap parameter) and PtState (a CM7 FB output) —
// and reports them on the bus as DynEcho, DynLed and DynPt. The point is the cross-core paths (load telemetry, the bulk
// model-stream, the signals both ways), not real dynamics.

import ports

pub struct DynamicsModel {
pub mut:
	ticks u32
	acc   u32 = 1
}

pub fn (mut fb DynamicsModel) on_5ms(inp ports.DynamicsModelIn, mut out ports.DynamicsModelOut) {
	fb.ticks++
	// ~0.8 ms at 200 MHz on a 5 ms period => ~15% steady CM4 load (sub-tick, so no overrun);
	// bulkperf's burst pushes the core toward 100% on top of this.
	mut a := fb.acc
	for _ in 0 .. 10_000 {
		a = a * 1664525 + 1013904223
	}
	fb.acc = a
	// publish the estimate cross-core (xioc slot) — the CM7 PowertrainCtrl reads it. This is also
	// the observable sink that keeps the burn from being dead-code-eliminated (no __global needed).
	out.torque_estimate.nm = a % 500
	// DynEcho: the command the CM7 comm thread checked and handed down, sent back while its receive
	// status is ok; otherwise 0xFFFFFF00 | status (never received 0, timeout 2, integrity 3)
	out.dyn_echo.cmd = if inp.dyn_cmd.status == .ok {
		inp.dyn_cmd.cmd
	} else {
		u32(0xFFFFFF00) | u32(u8(inp.dyn_cmd.status))
	}
	// DynLed: the LED level as the CM4 sees it (the CM7 drives LD3 from the same decode), held to
	// the coded cap — a parameter the CM7's journal keeps and hands down
	cap := u32(inp.dyn_led_cap.permille)
	out.dyn_led.permille = if inp.host_led_level.permille > cap {
		cap
	} else {
		inp.host_led_level.permille
	}
	// DynKept: a persisted value the CM7's journal keeps for this FB — a DynCmd in 0xFE000000 ..
	// 0xFEFFFFFF sets its low 24 bits; restored before the first dispatch, so it survives resets
	mut kept := inp.dyn_kept.v
	if inp.dyn_cmd.status == .ok && inp.dyn_cmd.cmd >> 24 == 0xFE {
		kept = inp.dyn_cmd.cmd & 0x00FF_FFFF
	}
	out.dyn_kept.v = kept
	out.dyn_kept_out.v = kept
	// DynCmdRejected: a DynCmd in 0xFD000000 .. 0xFDFFFFFF fails the test, anything else passes it —
	// the current result every dispatch; the CM7's fault memory keeps the history
	out.fault.dyn_cmd_rejected = if inp.dyn_cmd.status == .ok && inp.dyn_cmd.cmd >> 24 == 0xFD {
		.failed
	} else {
		.passed
	}
	// DynPt: the CM7 FB's sequence when both PtState lanes came from one publish, 0 before the
	// first one (the port default), 0xFFFFFFFF for lanes that do not belong together.
	out.dyn_pt.seq = if inp.pt_state.seq == 0 && inp.pt_state.inv == 0 {
		u32(0)
	} else if inp.pt_state.inv == ~inp.pt_state.seq {
		inp.pt_state.seq
	} else {
		u32(0xFFFFFFFF)
	}
}
