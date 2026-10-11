// doipcfg — a DoIP entity's ISO 13400-2 transport policy as configuration, BUILD-TIME: read from a
// [doip] table (loom2v) or a system.toml node's `doip` inline table (sysmodel), checked, and
// written back as [doip] lines (sysgen). One parser, one checker and one writer, so the node gate
// and syscheck cannot disagree about what a policy may say. The numbers — bounds, defaults, the
// sizes of the arrays the runtime holds it in — are comm/doip policy.v's.
module doipcfg

import toml
import comm.doip
import comm.uds

// the policy's keys: the same names in ecu.toml's [doip] and a node's `doip`
pub const list_keys = ['testers', 'activation_types']
pub const int_keys = ['initial_inactivity_ms', 'general_inactivity_ms', 'announce_count',
	'announce_interval_ms', 'route_level']
// allow_bench_key: the node may answer 0x27 with blobly_net's PUBLIC reference key over the
// network — a bench posture, opted into by name (bench_key_refusal)
pub const bench_key = 'allow_bench_key'

// keys: every policy key, lists first
pub fn keys() []string {
	mut k := list_keys.clone()
	k << int_keys
	k << bench_key
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
	// allow_bench_key as authored (absent = false); bench_key_bad: authored, but not a boolean
	allow_bench_key     bool
	has_allow_bench_key bool
	bench_key_bad       bool
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
	if v := m[bench_key] {
		if v is bool {
			p.allow_bench_key = v
			p.has_allow_bench_key = true
		} else {
			p.bench_key_bad = true
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
		'route_level' { doip.route_level }
		else { doip.announce_interval_ms }
	}
}

// problems: everything the entity could not serve as written, one sentence each, naming the key
pub fn (p Policy) problems() []string {
	mut errs := []string{}
	if p.bench_key_bad {
		errs << '`${bench_key}` must be true or false'
	}
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
	level := p.int_of('route_level')
	if level < 1 || level > uds.max_security_level {
		errs << '`route_level` ${level} is not a security level (1..${uds.max_security_level})'
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
	if p.has_allow_bench_key {
		b << '${bench_key} = ${p.allow_bench_key}'
	}
	return b
}

// ---- REQ-NET-012: what a server reachable over the network must gate ----
// One statement for the node gate (loom2v validate_doip) and syscheck (sysmodel check_doip).

// open_services: what a network tester may run before it has authenticated — reach and keep a
// session (0x10, 0x3E) and authenticate in it (0x27), which no 0x27 gate can itself require, and
// read (0x22, 0x19). 0x2E is gated per DID or by its own row (the node gate). Every OTHER service
// changes ECU state — 0x11 restarts it, 0x14 clears its fault memory, 0x85 freezes it, 0x28
// silences its bus — so this lists what is exempt, not what is gated.
pub const open_services = [u8(0x10), 0x19, 0x22, 0x27, 0x2E, 0x3E]

// needs_unlock: a network tester may run `sid` only once it has authenticated
pub fn needs_unlock(sid u8) bool {
	return sid !in open_services
}

// ServiceRow is one [uds] services row as this rule reads it
pub struct ServiceRow {
pub:
	sid      u8
	security i64 // 0 = none; as authored, so a level out of range is refused rather than truncated
}

// service_refusals: why a [uds] service table (`table` false = none declared, the default table)
// cannot be reachable over the network. Fail-closed: the default table serves every service the
// build performs with no security, whatever comm/uds learns to serve later, so a server reachable
// over the network declares its table; and in a table, every row this rule does not exempt needs a
// level. A row the build cannot perform is the [uds] gate's to refuse.
pub fn service_refusals(table bool, rows []ServiceRow) []string {
	if !table {
		return [
			'has no [uds] services table — the default table serves every service the build performs, 0x11 ECUReset included, to an unauthenticated network tester; declare one with a security level on each service that changes ECU state (REQ-NET-012)',
		]
	}
	mut errs := []string{}
	for r in rows {
		if r.security != 0 && !is_level(r.security) {
			errs << '[uds] services 0x${r.sid.hex()} security = ${r.security} is not a 0x27 level (1..${uds.max_security_level}) — it gates nothing (REQ-NET-012)'
			continue
		}
		if needs_unlock(r.sid) && r.security == 0 {
			errs << '[uds] services 0x${r.sid.hex()} changes ECU state but needs no security level — over the network it would act for an unauthenticated tester; give it `security = N` or leave it out (REQ-NET-012)'
		}
	}
	return errs
}

// handoff_refusal: '' unless the server has a programming handoff ([boot]) that a network tester
// could run unauthenticated. The handoff restarts the ECU into its bootloader — the state change
// 0x11 is, and more — so 0x10 02 is not covered by 0x10's exemption: its own row ("0x10 02") needs
// a level, as a 0x11 row does.
pub fn handoff_refusal(boot bool, security i64) string {
	if !boot || is_level(security) {
		return ''
	}
	if security != 0 {
		return '[uds] services "0x10 02" security = ${security} is not a 0x27 level (1..${uds.max_security_level}) — it gates nothing (REQ-NET-012)'
	}
	return '[boot]: the programming handoff (0x10 02) restarts the ECU into its bootloader, and the network reaches this server — over IP it would act for an unauthenticated tester; gate it: [uds] services "0x10 02" = { security = N } (REQ-NET-012)'
}

// bench_key_refusal: '' unless the 0x27 key a server reachable over the network answers with
// (`security_key`, [uds]) and `allow_bench_key` disagree. blobly_net's reference key is PUBLIC, so
// over a routed network it authenticates nobody: allowed only by name, as a bench posture.
pub fn bench_key_refusal(security_key string, allow bool) string {
	if security_key == 'reference' && !allow {
		return '[uds] security_key = "reference" is blobly_net\'s PUBLIC bench key, and the network reaches this server — over IP it authenticates nobody (REQ-NET-012). Set `${bench_key} = true` for a closed bench, or give the node the OEM\'s key (drop security_key)'
	}
	if allow && security_key != 'reference' {
		return '`${bench_key}` is set, but [uds] uses no bench key — it would mean nothing'
	}
	return ''
}

// is_level: a 0x27 security level (1..uds.max_security_level). Every rule here asks it, so a value
// out of range is never read as authentication anywhere.
pub fn is_level(l i64) bool {
	return l >= 1 && l <= uds.max_security_level
}

// DidWrite is a [[did]]'s write side, as far as REQ-NET-012 is concerned
pub struct DidWrite {
pub:
	id       int
	writable bool
	security i64 // the DID's own write gate; 0 = none
}

// did_refusals: a writable DID reachable over the network needs a write gate — its own, or the
// "0x2E" service row's (comm/uds checks the row first, so a gated row denies every DID behind it).
// The one rule loom2v's validate_doip and syscheck's check_doip both apply.
pub fn did_refusals(rows []ServiceRow, dids []DidWrite) []string {
	mut row_2e := i64(0)
	for r in rows {
		if r.sid == 0x2E && is_level(r.security) {
			row_2e = r.security
		}
	}
	mut errs := []string{}
	for d in dids {
		if d.security != 0 && !is_level(d.security) {
			errs << 'DID 0x${d.id.hex()} write security = ${d.security} is not a 0x27 level (1..${uds.max_security_level}) — it gates nothing (REQ-NET-012)'
			continue
		}
		if d.writable && d.security == 0 && row_2e == 0 {
			errs << 'makes DID 0x${d.id.hex()} writable from the network with no security level — gate it (write = { security = N }, or a security level on [uds] services "0x2E"), REQ-NET-012'
		}
	}
	return errs
}
