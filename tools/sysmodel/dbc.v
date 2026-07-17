// sysmodel/dbc — DBC conformance (REQ-TOPO-003, docs/multi-node.md). The DBC is
// the AUTHORED wire contract; the dissolution never edits it, it CONFORMS to it.
// For each cross-node signal this checks that its frame is defined in the bus's
// DBC, that the DBC's transmitter (BO_ sender) agrees with the declared
// producer, and that the signal's fields fit the frame — closing the
// implicit-frame-collision gap (a frame's single wire transmitter is the DBC's).
module sysmodel

import os
import tools.candb

// check_dbc_conformance loads each bus's DBC once and checks every system signal
// against it. A bus with no `dbc` is skipped (nothing to conform to).
pub fn check_dbc_conformance(s System) []Issue {
	mut issues := []Issue{}
	mut dbs := map[string]candb.Database{}
	mut loaded := map[string]bool{}
	for bus in s.buses {
		if bus.dbc == '' {
			continue
		}
		path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
		db := candb.load_dbc_file(path) or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${bus.name}": cannot load DBC "${bus.dbc}": ${err}'
			}
			continue
		}
		dbs[bus.name] = db
		loaded[bus.name] = true
	}
	for sig in s.signals {
		if sig.bus !in loaded {
			continue // no DBC, or a load error already reported
		}
		db := dbs[sig.bus]
		mut found := ?candb.Message(none)
		for m in db.messages {
			if m.name == sig.frame {
				found = m
				break
			}
		}
		m := found or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": frame "${sig.frame}" is not defined in bus "${sig.bus}" DBC'
			}
			continue
		}
		// the DBC transmitter must agree with the declared producer — the DBC's
		// single BO_ sender IS the frame's one wire owner (a placeholder sender
		// like Vector__XXX means "unspecified", not a mismatch).
		if m.sender != '' && !m.sender.starts_with('Vector__') && m.sender != sig.producer {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": DBC frame "${sig.frame}" is transmitted by "${m.sender}" but system.toml declares producer "${sig.producer}"'
			}
		}
		// the signal must be an SG_ IN the frame — loom2v resolves external signals
		// by exact DBC signal name, and aborts if it is absent — and its width must
		// match the fields (a single-field signal maps to one SG_ of that width).
		bits := field_bits(sig.fields)
		mut dbc_sig := ?candb.Signal(none)
		for ds in m.signals {
			if ds.name == sig.name {
				dbc_sig = ds
				break
			}
		}
		if ds := dbc_sig {
			if bits != 0 && ds.length != bits {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'signal "${sig.name}": fields are ${bits} bits but DBC SG_ "${sig.name}" in frame "${sig.frame}" is ${ds.length} bits'
				}
			}
		} else {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": frame "${sig.frame}" exists but has no SG_ named "${sig.name}" (loom2v resolves external signals by DBC signal name)'
			}
		}
		// the fields must also fit the frame's payload
		if bits > m.dlc * 8 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": fields need ${bits} bits but DBC frame "${sig.frame}" is only ${m.dlc} bytes (${m.dlc * 8} bits)'
			}
		}
	}
	return issues
}

// field_bits sums a signal's field widths (the [[signal]].fields types).
fn field_bits(fields map[string]string) int {
	mut total := 0
	for _, typ in fields {
		total += type_bits(typ)
	}
	return total
}

fn type_bits(typ string) int {
	return match typ {
		'bool' { 1 }
		'u8', 'i8' { 8 }
		'u16', 'i16' { 16 }
		'u32', 'i32', 'f32' { 32 }
		'u64', 'i64', 'f64' { 64 }
		else { 0 } // unknown type — width unbounded here; the node ecucheck names it
	}
}
