module ecu

// Mode arbiter — resolves concurrent mode requests within a mode group into one
// active mode by priority, and publishes it for COM / NM to gate on. No-alloc:
// fixed requester slots. (e.g. a group "powertrain network" with requesters that
// each ask for required/released; or an "ECU mode" group normal/diag/limp.)

pub const max_requesters = 16

pub struct ModeGroup {
pub mut:
	active  int // resolved, published mode value
	deflt   int // value when nobody requests
	req     [max_requesters]int // requested mode per requester, -1 = no request
	prio    [max_requesters]int // priority per requester (higher wins)
}

// new_group makes a group whose requester slots start empty and whose published
// value is `deflt` until something is requested.
pub fn new_group(deflt int) ModeGroup {
	mut g := ModeGroup{
		active: deflt
		deflt:  deflt
	}
	for i in 0 .. max_requesters {
		g.req[i] = -1
	}
	return g
}

// request: a requester asks for `mode` at `prio`. REQ-MODE-003.
pub fn (mut g ModeGroup) request(who int, mode int, prio int) {
	if who >= 0 && who < max_requesters {
		g.req[who] = mode
		g.prio[who] = prio
	}
}

// release: a requester withdraws its request. REQ-MODE-003.
pub fn (mut g ModeGroup) release(who int) {
	if who >= 0 && who < max_requesters {
		g.req[who] = -1
	}
}

// resolve picks the highest-priority active request and publishes it as `active`;
// with no requests it falls back to the default. REQ-MODE-001, REQ-MODE-002.
pub fn (mut g ModeGroup) resolve() int {
	mut best := -2147483648
	mut chosen := g.deflt
	mut any := false
	for i in 0 .. max_requesters {
		if g.req[i] >= 0 && g.prio[i] > best {
			best = g.prio[i]
			chosen = g.req[i]
			any = true
		}
	}
	g.active = if any { chosen } else { g.deflt }
	return g.active
}
