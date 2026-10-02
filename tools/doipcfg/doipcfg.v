// doipcfg — a DoIP entity's ISO 13400-2 transport policy as configuration, BUILD-TIME: read from a
// [doip] table (loom2v) or a system.toml node's `doip` inline table (sysmodel), checked, and
// written back as [doip] lines (sysgen). One parser, one checker and one writer, so the node gate
// and syscheck cannot disagree about what a policy may say. The numbers — bounds, defaults, the
// sizes of the arrays the runtime holds it in — are comm/doip policy.v's.
module doipcfg

import toml
import comm.doip

// the policy's keys: the same names in ecu.toml's [doip] and a node's `doip`
pub const list_keys = ['testers', 'activation_types']
pub const int_keys = ['initial_inactivity_ms', 'general_inactivity_ms', 'announce_count',
	'announce_interval_ms']

// keys: every policy key, lists first
pub fn keys() []string {
	mut k := list_keys.clone()
	k << int_keys
	return k
}

pub struct Policy {
pub mut:
	testers     []i64 // tester addresses allowed to activate routing
	has_testers bool  // authored (an empty list is refused, not read as "any")
	types       []i64 // activation types served
	has_types   bool
	// the integer keys as authored (absent = comm/doip's default)
	ints map[string]i64
}

// parse reads the policy keys of a [doip] / `doip` table; the second result names every policy key
// authored as anything but an integer (a list: anything but a list of integers) — narrowed, a float
// or a string would be a legal, DIFFERENT value. Keys that are not the policy's are the caller's.
pub fn parse(m map[string]toml.Any) (Policy, []string) {
	mut p := Policy{}
	mut not_int := []string{}
	for k in list_keys {
		v := m[k] or { continue }
		if v !is []toml.Any || !v.array().all(it is i64) {
			not_int << k
			continue
		}
		vals := v.array().map(it.i64())
		if k == 'testers' {
			p.testers = vals
			p.has_testers = true
		} else {
			p.types = vals
			p.has_types = true
		}
	}
	for k in int_keys {
		v := m[k] or { continue }
		if v is i64 {
			p.ints[k] = v
		} else {
			not_int << k
		}
	}
	return p, not_int
}

// int_of: an integer key, or comm/doip's default for it
pub fn (p Policy) int_of(k string) i64 {
	if v := p.ints[k] {
		return v
	}
	return match k {
		'initial_inactivity_ms' { doip.initial_inactivity_ms }
		'general_inactivity_ms' { doip.general_inactivity_ms }
		'announce_count' { doip.announce_count }
		else { doip.announce_interval_ms }
	}
}

// problems: everything the entity could not serve as written, one sentence each, naming the key
pub fn (p Policy) problems() []string {
	mut errs := []string{}
	if p.has_testers && p.testers.len == 0 {
		errs << '`testers` is empty — absent admits any tester address (0x0E00..0x0FFF); an empty list would read as that too'
	}
	if p.testers.len > doip.max_testers {
		errs << '`testers` lists ${p.testers.len} addresses — at most ${doip.max_testers}'
	}
	for i, t in p.testers {
		if !doip.tester_address_ok(t) {
			errs << '`testers` entry 0x${t:04X} is not a tester address (0x0E00..0x0FFF)'
		} else if t in p.testers[..i] {
			errs << '`testers` lists 0x${t:04X} twice'
		}
	}
	if p.has_types && p.types.len == 0 {
		errs << '`activation_types` is empty — no tester could activate routing (absent = [0x00])'
	}
	if p.types.len > doip.max_act_types {
		errs << '`activation_types` lists ${p.types.len} types — at most ${doip.max_act_types}'
	}
	for i, t in p.types {
		if !doip.activation_type_ok(t) {
			errs << 'activation type 0x${t:02X} is not one the entity can serve (0x00, 0x01, 0xE1..0xFF; 0xE0 central security is not implemented)'
		} else if t in p.types[..i] {
			errs << '`activation_types` lists 0x${t:02X} twice'
		}
	}
	initial := p.int_of('initial_inactivity_ms')
	general := p.int_of('general_inactivity_ms')
	if !doip.timers_ok(initial, general) {
		errs << '`initial_inactivity_ms` ${initial} / `general_inactivity_ms` ${general} out of bounds (${doip.initial_inactivity_min_ms}..${doip.initial_inactivity_max_ms} and ${doip.general_inactivity_min_ms}..${doip.general_inactivity_max_ms} ms, initial <= general)'
	}
	count := p.int_of('announce_count')
	interval := p.int_of('announce_interval_ms')
	if !doip.announce_ok(count, interval) {
		errs << '`announce_count` ${count} / `announce_interval_ms` ${interval} out of bounds (0..${doip.announce_count_max} of ${doip.announce_interval_min_ms}..${doip.announce_interval_max_ms} ms, at most ${doip.announce_total_max_ms} ms in all — the doip thread accepts no tester while it announces)'
	}
	return errs
}

// lines: the policy as [doip] lines, one-to-one under the same names (what is absent stays absent,
// so it takes the default where it is read)
pub fn (p Policy) lines() []string {
	mut b := []string{}
	if p.has_testers {
		b << 'testers = [${p.testers.map('0x${it:04X}').join(', ')}]'
	}
	if p.has_types {
		b << 'activation_types = [${p.types.map('0x${it:02X}').join(', ')}]'
	}
	for k in int_keys {
		if v := p.ints[k] {
			b << '${k} = ${v}'
		}
	}
	return b
}
