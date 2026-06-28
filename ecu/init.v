module ecu

// Deterministic init sequencer — runs the configured modules in order, honouring
// declared dependencies, and stops on the first failure. No-alloc: a fixed phase
// table + fn pointers (no captured state), driven by the Conductor at Startup.

pub const max_phases = 32

// One init phase. `deps` is a bitmask of phase indices that must be initialised
// first; `run` does the init (true on success); `stop` undoes it (for shutdown).
pub struct Phase {
pub:
	deps u32
	run  fn () bool = unsafe { nil }
	stop fn ()      = unsafe { nil }
}

pub struct InitSeq {
pub mut:
	done   u32 // bitmask of completed phase indices
	failed int = -1 // index of the phase that failed or whose dep was unmet, else -1
}

// run executes phases[0..n] in declaration order.
//   REQ-INIT-001 — configured, deterministic order.
//   REQ-INIT-002 — a phase is not started before its declared deps are done.
//   REQ-INIT-003 — on a failure, stop and record the failing phase index.
pub fn (mut s InitSeq) run(phases [max_phases]Phase, n int) bool {
	count := if n > max_phases { max_phases } else { n } // never index past the table
	for i := 0; i < count; i++ {
		p := phases[i]
		if p.deps & s.done != p.deps {
			s.failed = i // a dependency was not initialised before this phase
			return false
		}
		if !p.run() {
			s.failed = i
			return false
		}
		s.done |= u32(1) << u32(i)
	}
	return true
}

// stop tears down the completed phases in the REVERSE of init order.
//   REQ-ECU-005 — shut down in the reverse of the init order.
pub fn (mut s InitSeq) stop(phases [max_phases]Phase, n int) {
	count := if n > max_phases { max_phases } else { n }
	for i := count - 1; i >= 0; i-- {
		if s.done & (u32(1) << u32(i)) != 0 {
			phases[i].stop()
			s.done &= ~(u32(1) << u32(i))
		}
	}
}
