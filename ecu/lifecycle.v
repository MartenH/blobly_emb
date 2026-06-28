module ecu

// ECU lifecycle state machine (the Conductor's core). Sequences the ECU through
// Startup -> Run -> (PrepareSleep) -> Sleep -> Shutdown from a small demand input
// each tick. No-alloc value type. The actual init/teardown is the InitSeq; NM,
// diagnostics, and the application feed the demand.

pub enum Mode {
	startup
	run
	prepare_sleep
	sleep
	shutdown
}

// Demand: everything the Conductor arbitrates, gathered each tick.
pub struct Demand {
pub:
	init_done    bool // all init phases completed (gate Startup -> Run)
	network_busy bool // any network requires staying awake (from NM)
	diag_active  bool // a diagnostic session is open
	app_busy     bool // a function requests the ECU stay in Run
	wakeup       bool // a wakeup source is active (Sleep -> Run)
	shutdown_req bool // power-down requested
}

pub struct Lifecycle {
pub mut:
	mode Mode = .startup
}

fn (d Demand) any_demand() bool {
	return d.network_busy || d.diag_active || d.app_busy
}

// step advances the ECU mode from the current demand and returns the new mode.
//   REQ-ECU-001 — sequence Startup/Run/Sleep/Shutdown.
//   REQ-ECU-002 — enter Run only after init completed.
//   REQ-ECU-003 — Run -> sleep only when no network/diag/app needs it.
//   REQ-ECU-004 — Sleep -> Run on a wakeup source.
pub fn (mut l Lifecycle) step(d Demand) Mode {
	match l.mode {
		.startup {
			if d.shutdown_req {
				l.mode = .shutdown // abort bring-up on a power-down request
			} else if d.init_done {
				l.mode = .run
			}
		}
		.run {
			if d.shutdown_req {
				l.mode = .shutdown
			} else if !d.any_demand() {
				l.mode = .prepare_sleep
			}
		}
		.prepare_sleep {
			if d.shutdown_req {
				l.mode = .shutdown
			} else if d.any_demand() {
				l.mode = .run
			} else {
				l.mode = .sleep
			}
		}
		.sleep {
			if d.shutdown_req {
				l.mode = .shutdown // a power-down request is honoured even from Sleep
			} else if d.wakeup || d.any_demand() {
				l.mode = .run
			}
		}
		.shutdown {}
	}
	return l.mode
}
