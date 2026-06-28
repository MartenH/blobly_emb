module ecu

// @verifies REQ-ECU-001, REQ-ECU-002, REQ-ECU-003, REQ-ECU-004, REQ-ECU-005
// @verifies REQ-INIT-001, REQ-INIT-002, REQ-INIT-003
// @verifies REQ-MODE-001, REQ-MODE-002, REQ-MODE-003

// --- shared init-phase scaffolding (module-level: no closures) ---------------
__global ( order []int )

fn p0() bool { order << 0 return true }
fn p1() bool { order << 1 return true }
fn p2() bool { order << 2 return true }
fn pfail() bool { return false }
fn s0() { order << 100 }
fn s1() { order << 101 }
fn s2() { order << 102 }
fn noop() {}

// REQ-INIT-001: phases run in declared order; REQ-INIT-002: deps before dependents.
fn test_init_runs_in_order() {
	order = []int{}
	mut ph := [max_phases]Phase{}
	ph[0] = Phase{
		deps: 0
		run:  p0
		stop: s0
	}
	ph[1] = Phase{
		deps: u32(1) << 0 // needs phase 0
		run:  p1
		stop: s1
	}
	ph[2] = Phase{
		deps: u32(1) << 1 // needs phase 1
		run:  p2
		stop: s2
	}
	mut seq := InitSeq{}
	assert seq.run(ph, 3)
	assert seq.failed == -1
	assert order == [0, 1, 2]
}

// REQ-INIT-002: a phase whose dependency is not yet done fails (misordered config).
fn test_init_dependency_unmet() {
	order = []int{}
	mut ph := [max_phases]Phase{}
	ph[0] = Phase{
		deps: u32(1) << 1 // depends on phase 1, which runs later -> unmet
		run:  p0
		stop: s0
	}
	ph[1] = Phase{
		deps: 0
		run:  p1
		stop: s1
	}
	mut seq := InitSeq{}
	assert !seq.run(ph, 2)
	assert seq.failed == 0
}

// REQ-INIT-003: a failing phase stops the sequence and is reported.
fn test_init_halts_on_failure() {
	order = []int{}
	mut ph := [max_phases]Phase{}
	ph[0] = Phase{
		run:  p0
		stop: s0
	}
	ph[1] = Phase{
		run:  pfail
		stop: noop
	}
	ph[2] = Phase{
		run:  p2
		stop: s2
	}
	mut seq := InitSeq{}
	assert !seq.run(ph, 3)
	assert seq.failed == 1
	assert order == [0] // phase 2 never ran
}

// REQ-ECU-005: shutdown tears down completed phases in reverse of init order.
fn test_shutdown_reverse_order() {
	order = []int{}
	mut ph := [max_phases]Phase{}
	ph[0] = Phase{
		run:  p0
		stop: s0
	}
	ph[1] = Phase{
		run:  p1
		stop: s1
	}
	ph[2] = Phase{
		run:  p2
		stop: s2
	}
	mut seq := InitSeq{}
	assert seq.run(ph, 3)
	seq.stop(ph, 3)
	assert order == [0, 1, 2, 102, 101, 100] // init 0,1,2 then stop 2,1,0
}

// REQ-ECU-001/002: lifecycle reaches Run only after init is done.
fn test_lifecycle_run_after_init() {
	mut l := Lifecycle{}
	assert l.mode == .startup
	assert l.step(Demand{ init_done: false }) == .startup
	assert l.step(Demand{ init_done: true }) == .run
}

// REQ-ECU-003: Run -> sleep only when nothing needs the ECU.
fn test_lifecycle_run_to_sleep_gated() {
	mut l := Lifecycle{
		mode: .run
	}
	// still needed -> stays in Run
	assert l.step(Demand{ network_busy: true }) == .run
	assert l.step(Demand{ diag_active: true }) == .run
	assert l.step(Demand{ app_busy: true }) == .run
	// nothing needs it -> prepare_sleep -> sleep
	assert l.step(Demand{}) == .prepare_sleep
	assert l.step(Demand{}) == .sleep
}

// REQ-ECU-004: Sleep -> Run on a wakeup source.
fn test_lifecycle_wake() {
	mut l := Lifecycle{
		mode: .sleep
	}
	assert l.step(Demand{}) == .sleep
	assert l.step(Demand{ wakeup: true }) == .run
}

// REQ-ECU-005: a shutdown request reaches Shutdown from Sleep (not only from Run),
// so the ordered teardown is never skipped.
fn test_lifecycle_shutdown_from_sleep() {
	mut l := Lifecycle{
		mode: .sleep
	}
	assert l.step(Demand{ wakeup: true, shutdown_req: true }) == .shutdown
}

// REQ-MODE-001/002: highest priority request is resolved and published.
fn test_mode_priority() {
	mut g := new_group(0)
	g.request(0, 7, 1) // requester 0 wants mode 7 @prio 1
	g.request(1, 9, 5) // requester 1 wants mode 9 @prio 5 (wins)
	assert g.resolve() == 9
	assert g.active == 9
}

// REQ-MODE-003: releasing a request changes the resolved mode; empty -> default.
fn test_mode_release() {
	mut g := new_group(0)
	g.request(0, 7, 1)
	g.request(1, 9, 5)
	assert g.resolve() == 9
	g.release(1)
	assert g.resolve() == 7 // 9 withdrawn, 7 remains
	g.release(0)
	assert g.resolve() == 0 // nothing requested -> default
}
