module ecu

// Mode arbiter — resolves concurrent mode requests within a mode group into one
// active mode by priority, and publishes it for COM / NM to gate on. No-alloc:
// fixed requester slots. (e.g. a group "powertrain network" with requesters that
// each ask for required/released; or an "ECU mode" group normal/diag/limp.)

pub const max_requesters = 16

pub struct ModeGroup {
pub mut:
	active int // resolved, published mode value
	deflt  int // value when nobody requests
	// `has[i]` (zero value false) is the no-request sentinel, so a bare
	// `ModeGroup{}` literal is already empty — no init function required.
	has  [max_requesters]bool
	req  [max_requesters]int // requested mode per requester (valid when has[i])
	prio [max_requesters]int // priority per requester (higher wins)
}

// new_group is a convenience that publishes `deflt` until something is requested.
// A plain `ModeGroup{deflt: x}` is equally valid — the zero value is empty.
pub fn new_group(deflt int) ModeGroup {
	return ModeGroup{
		active: deflt
		deflt:  deflt
	}
}

// request: a requester asks for `mode` at `prio`. REQ-MODE-003.
pub fn (mut g ModeGroup) request(who int, mode int, prio int) {
	if who >= 0 && who < max_requesters {
		g.has[who] = true
		g.req[who] = mode
		g.prio[who] = prio
	}
}

// release: a requester withdraws its request. REQ-MODE-003.
pub fn (mut g ModeGroup) release(who int) {
	if who >= 0 && who < max_requesters {
		g.has[who] = false
	}
}

// resolve picks the highest-priority active request and publishes it as `active`;
// with no requests it falls back to the default. REQ-MODE-001, REQ-MODE-002.
pub fn (mut g ModeGroup) resolve() int {
	mut best := -2147483648
	mut chosen := g.deflt
	mut any := false
	for i in 0 .. max_requesters {
		if g.has[i] && g.prio[i] > best {
			best = g.prio[i]
			chosen = g.req[i]
			any = true
		}
	}
	g.active = if any { chosen } else { g.deflt }
	return g.active
}
