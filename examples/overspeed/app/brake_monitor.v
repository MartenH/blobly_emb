module app

import sig
import ports

// BrakeMonitor (CTRL): reports what it sees of BrakePressure's reception — the RxStatus the bridge
// owns and the E2E lost-frame count — on BrakeReport, so a tester can observe the status an FB
// actually receives (docs/diagnostics.md §3.2).
pub struct BrakeMonitor {}

pub fn (mut fb BrakeMonitor) on_10ms(inp ports.BrakeMonitorIn, mut out ports.BrakeMonitorOut) {
	out.brake_rx_status = sig.BrakeRxStatus{
		code: u8(inp.brake_pressure.status)
	}
	out.brake_lost = sig.BrakeLost{
		count: inp.brake_pressure.lost
	}
}
