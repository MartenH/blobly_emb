// sysmodel/dbc — DBC conformance (REQ-TOPO-003, docs/multi-node.md). The DBC is
// the AUTHORED wire contract; the dissolution never edits it, it CONFORMS to it.
// For each cross-node signal this checks that its frame is defined in the bus's
// DBC, that the DBC's transmitter (BO_ sender) agrees with the declared
// producer, and that the signal's fields fit the frame — closing the
// implicit-frame-collision gap (a frame's single wire transmitter is the DBC's).
module sysmodel

import os
import tools.candb

// check_route_dbc validates a SIGNAL route against the DESTINATION bus's DBC —
// check_dbc_conformance only checks a signal against its OWN (source) bus, so a
// route whose destination SG_ has an incompatible width/signedness, or whose
// destination frame is transmitted by another node, would otherwise slip through
// (the gateway's loom2v gate is deferred). The re-encode must match the dest wire
// contract and the gateway must own the destination frame (REQ-TOPO-003/-012).
pub fn check_route_dbc(s System) []Issue {
	mut issues := []Issue{}
	for r in s.routes {
		if r.signal == '' || r.to == '' {
			continue
		}
		to := s.bus_by_name(r.to) or { continue }
		sig := s.signal_by_name(r.signal) or { continue }
		// a routed signal must have a destination DBC to re-encode into. Reject a
		// dest bus with no `dbc` HERE so syscheck and sysgen fail on the same contract
		// (sysgen's frame_of_signal would otherwise fail only mid-generation).
		if to.dbc == '' {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": destination bus "${r.to}" has no `dbc` to re-encode signal "${r.signal}" into'
			}
			continue
		}
		path := if os.is_abs_path(to.dbc) { to.dbc } else { os.join_path(s.dir, to.dbc) }
		db := candb.load_dbc_file(path) or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": cannot load destination DBC "${to.dbc}" for signal "${r.signal}": ${err}'
			}
			continue
		}
		mut dsg := ?candb.Signal(none)
		mut dmsg := ?candb.Message(none)
		mut sender := ''
		for m in db.messages {
			for sg in m.signals {
				if sg.name == r.signal {
					dsg = sg
					dmsg = m
					sender = m.sender
					break
				}
			}
		}
		// signal-not-in-dest-DBC: report HERE too, so syscheck rejects the same
		// contract sysgen's frame_of_signal does (not only mid-generation).
		ds := dsg or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": signal "${r.signal}" is not defined in destination DBC "${to.dbc}" (bus "${r.to}")'
			}
			continue
		}
		dm := dmsg or { continue }
		// a multiplexed destination SG_ needs selector semantics the dissolution codec
		// has no support for (same limit as the source-side check) — the re-encode
		// would write an inactive/overlapping branch.
		if ds.is_multiplexor || ds.is_multiplexed {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": destination DBC SG_ "${r.signal}" (bus "${r.to}") is multiplexed — the dissolution codec has no multiplexor support'
			}
		}
		// the destination frame is re-encoded + transmitted by the GATEWAY.
		if sender != '' && !sender.starts_with('Vector__') && sender != r.gateway {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-012'
				msg:      'route on "${r.gateway}": destination frame for "${r.signal}" on bus "${r.to}" is transmitted by "${sender}" in the DBC, not the gateway'
			}
		}
		// the re-encode must fit the destination SG_ width + signedness.
		bits := field_bits(sig.fields)
		if bits != 0 && ds.length != bits {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": signal "${r.signal}" fields are ${bits} bits but destination DBC SG_ is ${ds.length} bits (bus "${r.to}")'
			}
		}
		// ...and fit the destination FRAME's payload — a wide SG_ in a short BO_ would
		// be truncated to the declared DLC on the wire (the source-side check does this).
		if bits > dm.dlc * 8 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": signal "${r.signal}" needs ${bits} bits but destination frame "${dm.name}" is only ${dm.dlc} bytes (${dm.dlc * 8} bits) on bus "${r.to}"'
			}
		}
		if want := field_signed(sig.fields) {
			if want != ds.is_signed {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'route on "${r.gateway}": signal "${r.signal}" is ${if want {
						'signed'
					} else {
						'unsigned'
					}} but destination DBC SG_ is ${if ds.is_signed {
						'signed'
					} else {
						'unsigned'
					}} (bus "${r.to}")'
				}
			}
		}
	}
	return issues
}

// check_dbc_conformance loads each bus's DBC once and checks every system signal
// against it. A bus with no `dbc` is skipped (nothing to conform to).
pub fn check_dbc_conformance(s System) []Issue {
	mut issues := []Issue{}
	mut dbs := map[string]candb.Database{}
	mut loaded := map[string]bool{}
	mut has_dbc := map[string]bool{}
	for bus in s.buses {
		has_dbc[bus.name] = bus.dbc != ''
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
	// two BO_ with the SAME CAN id (differently named) are two frames aliasing one
	// wire id. Frame ownership is keyed by NAME, so the generator would emit both
	// transmitters and distinct producers send incompatible payloads under one id.
	// candb keeps duplicate-id messages, so reject the ambiguous DBC here.
	for bus in s.buses {
		if bus.name !in loaded {
			continue
		}
		mut id_seen := map[u32]string{}
		for msg in dbs[bus.name].messages {
			if prev := id_seen[msg.id] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'bus "${bus.name}": DBC frames "${prev}" and "${msg.name}" share CAN id 0x${msg.id.hex()} — one frame per id'
				}
			} else {
				id_seen[msg.id] = msg.name
			}
		}
	}
	// every node the DBC names — a BO_ transmitter or an SG_ receiver — must be
	// declared in that DBC's own BU_ roster. candb parses BU_ into db.nodes but
	// nothing else consumes it, so a node named nowhere in BU_ (a dangling
	// reference — an invalid DBC) slips through: the producer↔sender check below
	// compares the sender to system.toml, so a node renamed ONLY in BU_ leaves the
	// sender matching the producer and passes; a receiver isn't cross-checked at
	// all. This catches a typo'd or renamed node roster at its source.
	for bus in s.buses {
		if bus.name !in loaded {
			continue
		}
		db := dbs[bus.name]
		for msg in db.messages {
			if msg.sender != '' && !msg.sender.starts_with('Vector__')
				&& msg.sender !in db.nodes {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'bus "${bus.name}": DBC frame "${msg.name}" is transmitted by "${msg.sender}" but that node is not in the DBC BU_ list [${db.nodes.join(', ')}]'
				}
			}
			for sig in msg.signals {
				for rx in sig.receivers {
					if rx != '' && !rx.starts_with('Vector__') && rx !in db.nodes {
						issues << Issue{
							severity: .error
							req:      'REQ-TOPO-003'
							msg:      'bus "${bus.name}": DBC signal "${sig.name}" in frame "${msg.name}" is received by "${rx}" but that node is not in the DBC BU_ list [${db.nodes.join(', ')}]'
						}
					}
				}
			}
		}
	}
	// application frame ids must not fall in the NM peer range: loom2v arms the
	// whole peers range as the NM receiver, so a BO_ inside it is consumed as an
	// NM frame, and one at peers.lo + node collides with that node's alive tx.
	for bus in s.buses {
		if !bus.has_nm_cluster || bus.name !in loaded {
			continue
		}
		for msg in dbs[bus.name].messages {
			if msg.id >= bus.nm_peers_lo && msg.id <= bus.nm_peers_hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'bus "${bus.name}": DBC frame "${msg.name}" id 0x${msg.id.hex()} falls in the NM peer range [0x${bus.nm_peers_lo.hex()},0x${bus.nm_peers_hi.hex()}] — application ids must not overlap NM'
				}
			}
		}
	}
	for sig in s.signals {
		// loom2v MUST load a DBC for any bus carrying external (cross-node)
		// signals, so a bus with signals but no `dbc` cannot be code-generated.
		if !(has_dbc[sig.bus] or { false }) {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": bus "${sig.bus}" carries cross-node signals but declares no `dbc`'
			}
			continue
		}
		if sig.bus !in loaded {
			continue // DBC declared but failed to load — already reported
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
			// a multiplexed/multiplexor SG_ needs selector semantics the dissolution
			// codec doesn't carry — the generated getters/setters ignore the switch,
			// so an inactive branch is (de)serialized as if always present.
			if ds.is_multiplexed || ds.is_multiplexor {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'signal "${sig.name}": DBC SG_ "${sig.name}" is multiplexed — the dissolution codec has no multiplexor support'
				}
			}
			if bits != 0 && ds.length != bits {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'signal "${sig.name}": fields are ${bits} bits but DBC SG_ "${sig.name}" in frame "${sig.frame}" is ${ds.length} bits'
				}
			}
			// signedness must agree: a signed SG_ decodes to negative physical
			// values, which the bridge then casts to the declared V type — a u-field
			// on a signed SG_ (or vice versa) flips the sign of high-bit values.
			if want := field_signed(sig.fields) {
				if want != ds.is_signed {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-003'
						msg:      'signal "${sig.name}": field is ${if want {
							'signed'
						} else {
							'unsigned'
						}} but DBC SG_ "${sig.name}" is ${if ds.is_signed {
							'signed'
						} else {
							'unsigned'
						}}'
					}
				}
			}
		} else {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": frame "${sig.frame}" exists but has no SG_ named "${sig.name}" (loom2v resolves external signals by DBC signal name)'
			}
		}
		// the SG_ name must be UNIQUE across the bus DBC: loom2v resolves an
		// external signal by name and takes the FIRST matching message, so a name
		// that also lives in another frame could be sent/received on the wrong one.
		mut in_frames := []string{}
		for msg in db.messages {
			for ds in msg.signals {
				if ds.name == sig.name {
					in_frames << msg.name
					break
				}
			}
		}
		if in_frames.len > 1 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": DBC signal name appears in ${in_frames.len} frames (${in_frames.join(', ')}) — loom2v resolves by name to the first, so it must be unique'
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
// field_bits is the wire width of a signal's VALUE field — the `valid` metadata
// field is not serialized, so it doesn't count toward the DBC SG_ width.
fn field_bits(fields map[string]string) int {
	mut total := 0
	for name, typ in fields {
		if name == 'valid' {
			continue
		}
		total += type_bits(typ)
	}
	return total
}

// field_signed reports the declared signedness of a signal's single VALUE
// integer field (the `valid` metadata field is not on the wire), or none for a
// non-integer (bool/float — DBC signedness doesn't apply).
fn field_signed(fields map[string]string) ?bool {
	for name, typ in fields {
		if name == 'valid' {
			continue
		}
		return match typ {
			'i8', 'i16', 'i32', 'i64' { true }
			'u8', 'u16', 'u32', 'u64' { false }
			else { return none } // bool / float: skip the signedness check
		}
	}
	return none
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
