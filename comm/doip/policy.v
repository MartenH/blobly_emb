module doip

// What a DoIP entity may be configured to do — the routing-activation policy, its timers and its
// announcements — stated ONCE, as numbers: the runtime holds the policy in fixed arrays of these
// sizes, and the generator (loom2v [doip]) and the system check (syscheck, a node's `doip`) both
// refuse a configuration through these predicates, each with its own message.

// ISO 13400-2:2012 logical addresses: 0x0E00..0x0FFF are external test equipment (testers). A routing
// activation from any other source address is refused (0x00, unknown source address) — the
// whole range when no tester list is configured, the list when one is.
pub const tester_first = 0x0E00
pub const tester_last = 0x0FFF

// max_testers / max_act_types (doip.v, beside the arrays they size): the most tester addresses
// (`testers`) and activation types (`activation_types`) a node lists

// TCP_DATA sockets this entity serves at once (driver/eth/doip_netx.c: one socket, backlog 1) —
// what entity status reports as its maximum
pub const max_sockets = 1

// T_TCP_Initial_Inactivity (ISO 13400-2:2012, default 2 s): a connection that has not
// activated routing by then is closed, counted from accept. Configurable between the bounds.
pub const initial_inactivity_ms = 2000
pub const initial_inactivity_min_ms = 100
pub const initial_inactivity_max_ms = 60000

// T_TCP_General_Inactivity (default 5 min): an activated connection idle this long is closed.
// The maximum keeps the tick count in 32 bits at a 1 kHz ThreadX tick (MS_TICKS).
pub const general_inactivity_ms = 300000
pub const general_inactivity_min_ms = 1000
pub const general_inactivity_max_ms = 3600000

// A_DoIP_Announce_Num / A_DoIP_Announce_Interval (defaults 3 and 500 ms): the vehicle
// announcements broadcast once the link is up. 0 announcements is allowed (discovery is then by
// identification request only).
pub const announce_count = 3
pub const announce_count_max = 10
pub const announce_interval_ms = 500
pub const announce_interval_min_ms = 10
pub const announce_interval_max_ms = 10000

// tester_address_ok: a source address a tester may use (the range a `testers` entry must lie in)
pub fn tester_address_ok(a i64) bool {
	return a >= tester_first && a <= tester_last
}

// activation_type_ok: an activation type a node may list. ISO 13400-2:2012 defines 0x00
// default, 0x01 WWH-OBD, 0xE0 central security and 0xE1..0xFF VM-specific (0x02..0xDF are
// reserved). Every type listed is served as default routing — no authentication or confirmation
// step is implemented — so 0xE0 is refused: a tester asking for central security must not be
// told it got it.
pub fn activation_type_ok(t i64) bool {
	return t == 0x00 || t == 0x01 || (t >= 0xE1 && t <= 0xFF)
}

// timers_ok: both inactivity timers within their bounds, the initial one no longer than the
// general one (a connection is not given longer to activate than to idle once activated)
pub fn timers_ok(initial_ms i64, general_ms i64) bool {
	return initial_ms >= initial_inactivity_min_ms && initial_ms <= initial_inactivity_max_ms
		&& general_ms >= general_inactivity_min_ms && general_ms <= general_inactivity_max_ms
		&& initial_ms <= general_ms
}

// announce_ok: an announcement count and interval within their bounds
pub fn announce_ok(count i64, interval_ms i64) bool {
	return count >= 0 && count <= announce_count_max && interval_ms >= announce_interval_min_ms
		&& interval_ms <= announce_interval_max_ms
}
