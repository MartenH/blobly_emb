module ecumodel

import toml
import comm.isotp
import tools.cfgschema

// How a diagnostic connection states its CAN identifiers — one reader for an ecu.toml [isotp] and a
// system.toml node's `diag` (docs/can-tp.md §2), so the two ways of stating an id, the widths and
// the derivation are one policy wherever they are read:
//   - normal addressing: the ids as given, 11-bit, or 29-bit with `ext = true`
//     (REQ-CAN-TP-040); an id above 0x7FF without `ext` is refused, never promoted;
//   - normal fixed addressing (`addressing = "normal_fixed"`): the node's own address `sa` and the
//     tester's `ta`, one byte each, from which the 29-bit ids derive (isotp.fixed_id,
//     REQ-CAN-TP-041); ids or `ext` given beside them are refused — one way to state an id.

// AddrKeys names a table's keys: [isotp]'s rx_id / tx_id / functional_id, a diag's req / rsp.
pub struct AddrKeys {
pub:
	ctx        string // the schema table the keys are rows of (their bounds and choices)
	rx         string // the key of the id requests arrive on
	tx         string // the key of the id answers are sent on
	functional string // the functional id's key; '' = the table has none
	required   bool   // normal addressing must give rx and tx
	// walked: the schema walk has judged the table's TYPES before this reader runs (ecucheck walks
	// an ecu.toml, then runs ecumodel.validate), so a key of the wrong type is the walk's to say and
	// is read here as unreadable without a second refusal (cfgschema Key.own_check: said once).
	// A reader nothing walks before (system.toml, loom2v) says the type itself.
	walked bool
}

// isotp_keys: an ecu.toml [isotp] as ecumodel.validate reads it, after ecucheck's walk — rx_id and
// tx_id required with normal addressing
pub const isotp_keys = AddrKeys{
	ctx:        'isotp'
	rx:         'rx_id'
	tx:         'tx_id'
	functional: 'functional_id'
	required:   true
	walked:     true
}

// isotp_keys_unwalked: the same [isotp] read where no walk ran first (loom2v), which therefore
// refuses a key of the wrong type itself
pub const isotp_keys_unwalked = AddrKeys{
	...isotp_keys
	walked: false
}

// diag_keys: a system.toml node's diag allocation — req and rsp may be absent (no allocation);
// system.toml is never walked, so this reader says a wrong type
pub const diag_keys = AddrKeys{
	ctx:      'sys_diag'
	rx:       'req'
	tx:       'rsp'
	required: false
}

// DiagIds is a connection's identifiers as read: the request id, the response id, the functional
// id (0 = none), whether they are 29-bit, and whether they were derived by normal fixed addressing
// — then from the addresses read (`sa`, `ta`, and `functional_ta` where `functional` is not 0).
pub struct DiagIds {
pub:
	rx            u32
	tx            u32
	functional    u32
	ext           bool
	fixed         bool
	sa            u8
	ta            u8
	functional_ta u8
}

// states_ids: whether table `m` states any of a connection's addressing — an id, its format, or
// normal fixed addressing's keys. An ecu.toml [isotp] of a dissolved node that states none takes
// its node's diag allocation, which sysgen lowers into it (REQ-TOPO-014).
pub fn states_ids(k AddrKeys, m map[string]toml.Any) bool {
	for key in [k.rx, k.tx, k.functional, 'ext', 'addressing', 'sa', 'ta', 'functional_ta'] {
		if key != '' && key in m {
			return true
		}
	}
	return false
}

// diag_ids reads a connection's identifiers from table `m` (`what` names it in a refusal, e.g.
// '[isotp]' or 'node "x" diag') and returns them with every refusal. It ALWAYS returns the ids it
// read, refused or not — a reader that runs no gate (a partial node in sysmodel) must not drop
// them out of the collision checks: under normal addressing the numbers as read, under normal
// fixed addressing the derived ids when sa and ta are both readable addresses, else 0. Under an
// addressing it cannot read, the integers given for the ids, and nothing more is judged: every
// other key would be judged by the wrong format's rules, one mistake said once per key.
pub fn diag_ids(s cfgschema.Schema, k AddrKeys, m map[string]toml.Any, what string) (DiagIds, []string) {
	mut errs := []string{}
	formats := s.key(k.ctx, 'addressing').choices
	mut addressing := 'normal'
	if v := m['addressing'] {
		if v is string && v in formats {
			addressing = v
		} else {
			if v is string || !k.walked {
				shown := if v is string { '"${v}"' } else { v.to_toml() }
				errs << '${what} addressing ${shown} is not one of ${formats.map('"' + it + '"').join(', ')} — extended and mixed addressing are not supported'
			}
			return DiagIds{
				rx:         raw_id(m, k.rx)
				tx:         raw_id(m, k.tx)
				functional: raw_id(m, k.functional)
				ext:        if e := m['ext'] { e is bool && e.bool() } else { false }
			}, errs
		}
	}
	if addressing == 'normal_fixed' {
		for key in [k.rx, k.tx, k.functional, 'ext'] {
			if key != '' && key in m {
				errs << '${what} ${key} is given with addressing = "normal_fixed", whose ids derive from sa and ta — one way to state an id'
			}
		}
		sa, sa_ok := address_of(s, k, m, 'sa', 'the node\'s own address', what, true, mut errs)
		ta, ta_ok := address_of(s, k, m, 'ta', 'the tester\'s address', what, true, mut errs)
		fta, fta_ok := address_of(s, k, m, 'functional_ta', '', what, false, mut errs)
		if sa_ok && ta_ok && sa == ta {
			errs << '${what} sa and ta are both 0x${sa.hex()} — a request and its answer would be one id'
		}
		if !(sa_ok && ta_ok) {
			return DiagIds{
				ext:   true
				fixed: true
			}, errs
		}
		return DiagIds{
			rx:            isotp.fixed_id(false, sa, ta)
			tx:            isotp.fixed_id(false, ta, sa)
			functional:    if fta_ok { isotp.fixed_id(true, fta, ta) } else { u32(0) }
			ext:           true
			fixed:         true
			sa:            sa
			ta:            ta
			functional_ta: if fta_ok { fta } else { u8(0) }
		}, errs
	}
	for key in ['sa', 'ta', 'functional_ta'] {
		if key in m {
			errs << '${what} ${key} is for addressing = "normal_fixed" — normal addressing states ${k.rx} and ${k.tx}'
		}
	}
	mut ext := false
	if v := m['ext'] {
		if v is bool {
			ext = v
		} else if !k.walked {
			errs << '${what} ext must be a boolean (true: the ids are 29-bit)'
		}
	}
	rx := id_of(m, k.rx, ext, what, k.required, k.walked, mut errs)
	tx := id_of(m, k.tx, ext, what, k.required, k.walked, mut errs)
	functional := if k.functional != '' {
		id_of(m, k.functional, ext, what, false, k.walked, mut errs)
	} else {
		u32(0)
	}
	// the functional id is received beside the physical one: never one of the connection's own
	if functional != 0 && (functional == rx || functional == tx) {
		errs << '${what} ${k.functional} 0x${functional.hex()} is also the connection\'s physical ${k.rx} / ${k.tx}'
	}
	return DiagIds{
		rx:         rx
		tx:         tx
		functional: functional
		ext:        ext
	}, errs
}

// raw_id: the integer given for `key`, unjudged (0 when absent, not an integer, or no key)
fn raw_id(m map[string]toml.Any, key string) u32 {
	v := m[key] or { return 0 }
	return if v is i64 { u32(v) } else { 0 }
}

// id_of: an id under normal addressing — the number as read (0 when absent), refusing a missing
// required one, one that is not an integer (unless the walk said so: `walked`), one outside the
// 29-bit range and, without ext, one above 0x7FF
fn id_of(m map[string]toml.Any, key string, ext bool, what string, required bool, walked bool, mut errs []string) u32 {
	v := m[key] or {
		if required {
			errs << '${what} needs ${key} (normal addressing states the ids; or addressing = "normal_fixed" with sa and ta)'
		}
		return 0
	}
	read := u32(v.int())
	if v !is i64 {
		if !walked {
			errs << '${what} ${key} must be an integer'
		}
		return read
	}
	n := v.i64()
	if n < 0 || n > i64(isotp.ext_id_max) {
		errs << '${what} ${key} = 0x${n.hex()} is out of range (0x0..0x${isotp.ext_id_max.hex()})'
	} else if !ext && n > i64(isotp.std_id_max) {
		errs << '${what} ${key} 0x${n.hex()} must be a standard 11-bit id (<= 0x${isotp.std_id_max:X}) — ext = true makes it 29-bit'
	}
	return read
}

// address_of: a one-byte address of normal fixed addressing, and whether it is one (present, an
// integer, within its row's range); a missing `required` one, or a bad one, is refused (a wrong
// type only where no walk said it)
fn address_of(s cfgschema.Schema, k AddrKeys, m map[string]toml.Any, key string, role string, what string, required bool, mut errs []string) (u8, bool) {
	v := m[key] or {
		if required {
			errs << '${what} addressing = "normal_fixed" needs ${key} (${role})'
		}
		return 0, false
	}
	if v !is i64 {
		if !k.walked {
			errs << '${what} ${key} must be an integer'
		}
		return 0, false
	}
	row := s.key(k.ctx, key)
	n := v.i64()
	if !row.in_range(n) {
		errs << '${what} ${key} = 0x${n.hex()} is out of range (0x${row.min.hex()}..0x${row.max.hex()})'
		return 0, false
	}
	return u8(n), true
}

// route_id_errors: each [[doip.route]]'s ids in the routed node's format — tx_id / rx_id 11-bit
// unless `ext` is set, within the 29-bit range either way (REQ-NET-021). It runs in
// ecumodel.validate, after ecucheck's walk: a missing id, or a key of the wrong type, is the
// walk's to say (said once), and an `ext` that is not a boolean is read as 11-bit here.
pub fn route_id_errors(doc toml.Doc) []string {
	mut errs := []string{}
	dv := doc.value_opt('doip') or { return errs }
	if dv !is map[string]toml.Any {
		return errs
	}
	rv := dv.as_map()['route'] or { return errs }
	if rv !is []toml.Any {
		return errs
	}
	for e in rv.array() {
		if e !is map[string]toml.Any {
			continue
		}
		r := e.as_map()
		node := str_of(r, 'node')
		what := '[[doip.route]] "${node}"'
		ext := if v := r['ext'] { v is bool && v.bool() } else { false }
		for key in ['tx_id', 'rx_id'] {
			if v := r[key] {
				if v is i64 {
					id_of(r, key, ext, what, false, true, mut errs)
				}
			}
		}
	}
	return errs
}
