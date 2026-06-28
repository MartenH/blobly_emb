module wdg

// Sentinel — execution supervision that gates the hardware watchdog. Each
// supervised entity (a partition or FB) reports an alive checkpoint each cycle
// and, optionally, marks an activity window for deadline supervision. The HW
// watchdog is serviced only when every entity is healthy; otherwise the service
// is withheld and the hardware resets the ECU. No-alloc: fixed entity table.

pub const max_entities = 32

pub struct Entity {
pub:
	period_us   u64 // max time allowed between alive checkpoints
	deadline_us u64 // max duration of a marked activity (0 = no deadline check)
}

pub struct Supervisor {
pub mut:
	cfg           [max_entities]Entity // per-entity config (set at init)
	n             int
	last_alive_us [max_entities]u64
	start_us      [max_entities]u64
	active        [max_entities]bool
	tripped       bool // latched once a supervision failure is seen
}

// checkpoint: entity `id` reports alive at `now`. A checkpoint that arrives after
// its period has already elapsed latches the miss, so a late recovery between
// service() polls can't mask it. REQ-WDG-002.
pub fn (mut s Supervisor) checkpoint(id int, now u64) {
	if id >= 0 && id < s.n {
		if now - s.last_alive_us[id] > s.cfg[id].period_us {
			s.tripped = true
		}
		s.last_alive_us[id] = now
	}
}

// start / finish: bound an activity window for deadline supervision (REQ-WDG-003).
pub fn (mut s Supervisor) start(id int, now u64) {
	if id >= 0 && id < s.n {
		s.active[id] = true
		s.start_us[id] = now
	}
}

pub fn (mut s Supervisor) finish(id int, now u64) {
	if id >= 0 && id < s.n {
		if s.active[id] && s.cfg[id].deadline_us > 0
			&& now - s.start_us[id] > s.cfg[id].deadline_us {
			s.tripped = true // completed past its deadline — latch the overrun
		}
		s.active[id] = false
	}
}

// healthy: are all entities within their alive period (REQ-WDG-002) and not over
// their deadline (REQ-WDG-003) at `now`? Latches `tripped` on the first failure.
pub fn (mut s Supervisor) healthy(now u64) bool {
	for i := 0; i < s.n; i++ {
		if now - s.last_alive_us[i] > s.cfg[i].period_us {
			s.tripped = true
			return false // missed alive checkpoint
		}
		if s.active[i] && s.cfg[i].deadline_us > 0
			&& now - s.start_us[i] > s.cfg[i].deadline_us {
			s.tripped = true
			return false // exceeded deadline
		}
	}
	return true
}

// service: returns true iff the hardware watchdog should be kicked now — only when
// every entity is healthy (REQ-WDG-001). A failure latches `tripped`, and the
// service stays withheld from then on even if the entity recovers, so the HW
// watchdog always times out and resets the ECU. REQ-WDG-004.
pub fn (mut s Supervisor) service(now u64) bool {
	if s.tripped {
		return false // latched: a prior supervision failure keeps the dog hungry
	}
	return s.healthy(now)
}
