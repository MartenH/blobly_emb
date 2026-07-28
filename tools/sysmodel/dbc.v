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
// route_phys_range returns a DBC signal's [min, max] physical value (raw range
// scaled by factor/offset), for the route source-vs-dest range-containment check.
fn route_phys_capacity(sg candb.Signal) (f64, f64) {
	n := sg.length
	if sg.is_signed {
		half := f64(u64(1) << u64(n - 1))
		a := -half * sg.factor + sg.offset
		b := (half - 1) * sg.factor + sg.offset
		return if a < b { a, b } else { b, a }
	}
	rmax := f64((u64(1) << u64(n)) - 1)
	a := sg.offset
	b := rmax * sg.factor + sg.offset
	return if a < b { a, b } else { b, a }
}

fn route_phys_range(sg candb.Signal) (f64, f64) {
	clo, chi := route_phys_capacity(sg)
	if sg.maximum > sg.minimum {
		lo := if sg.minimum > clo { sg.minimum } else { clo }
		hi := if sg.maximum < chi { sg.maximum } else { chi }
		return lo, hi
	}
	return clo, chi
}

// route_val_phys_equal compares two DBC VAL_ enum tables by PHYSICAL value (a route
// transcodes factor/offset, so the same enum can have different raw keys).
fn route_sig_key_phys(s candb.Signal, raw u64) f64 {
	r := if s.is_signed { f64(i64(raw)) } else { f64(raw) }
	return r * s.factor + s.offset
}

fn route_val_tol(a candb.Signal, b candb.Signal) f64 {
	fa := if a.factor < 0 { -a.factor } else { a.factor }
	fb := if b.factor < 0 { -b.factor } else { b.factor }
	step := if fa < fb && fa > 0 { fa } else { fb }
	if step <= 0 {
		return 1e-9
	}
	return step * 0.5
}

fn route_f64_close(x f64, y f64, tol f64) bool {
	mut d := x - y
	if d < 0 {
		d = -d
	}
	return d < tol
}

fn route_val_phys_equal(a candb.Signal, b candb.Signal) bool {
	if a.values.len != b.values.len {
		return false
	}
	tol := route_val_tol(a, b)
	for ka, va in a.values {
		pa := route_sig_key_phys(a, ka)
		mut found := false
		for kb, vb in b.values {
			if vb == va && route_f64_close(route_sig_key_phys(b, kb), pa, tol) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// route_load_bus_dbc loads a bus's DBC (relative to the system dir), or returns an
// error Issue describing why the frame route can't be contract-checked.
fn route_load_bus_dbc(s System, r Route, b Bus, role string) !candb.Database {
	if b.dbc == '' {
		return error('${role} bus "${b.name}" has no `dbc` to define frame "${r.frame}"')
	}
	path := if os.is_abs_path(b.dbc) { b.dbc } else { os.join_path(s.dir, b.dbc) }
	return candb.load_dbc_file(path) or {
		return error('cannot load ${role} DBC "${b.dbc}" (bus "${b.name}"): ${err}')
	}
}

// route_msg_of finds a message by NAME in a DBC (frame routes name a DBC message).
fn route_msg_of(db candb.Database, frame string) ?candb.Message {
	for m in db.messages {
		if m.name == frame {
			return m
		}
	}
	return none
}

// sig_wire_diff returns '' when two DBC signals carry the same value on the wire —
// identical bit placement, scaling, sign, endianness, multiplexing, unit and VAL_
// table — or a human description of the FIRST wire difference. Node (receiver)
// names are deliberately not compared: they are per-bus topology, not the PDU.
fn sig_wire_diff(a candb.Signal, b candb.Signal) string {
	if a.start_bit != b.start_bit {
		return 'start bit ${a.start_bit} vs ${b.start_bit}'
	}
	if a.length != b.length {
		return 'length ${a.length} vs ${b.length}'
	}
	if a.factor != b.factor {
		return 'factor ${a.factor} vs ${b.factor}'
	}
	if a.offset != b.offset {
		return 'offset ${a.offset} vs ${b.offset}'
	}
	if a.minimum != b.minimum || a.maximum != b.maximum {
		return 'physical range [${a.minimum}|${a.maximum}] vs [${b.minimum}|${b.maximum}]'
	}
	if a.is_signed != b.is_signed {
		return 'signedness ${a.is_signed} vs ${b.is_signed}'
	}
	if a.byte_order != b.byte_order {
		return 'endianness ${a.byte_order} vs ${b.byte_order}'
	}
	if a.unit != b.unit {
		return 'unit "${a.unit}" vs "${b.unit}"'
	}
	if a.is_multiplexor != b.is_multiplexor || a.is_multiplexed != b.is_multiplexed
		|| a.multiplexor_value != b.multiplexor_value {
		return 'multiplexing differs'
	}
	// a RAW forward keeps the exact bits and (checked above) identical factor/offset,
	// so compare VAL_ enum tables by EXACT raw key — not through f64 (route_val_phys_
	// equal), whose >2^53 rounding could let two large raw keys collapse and swap labels.
	if a.values.len != b.values.len {
		return 'VAL_ (value table) size differs'
	}
	for k, va in a.values {
		if (b.values[k] or { '' }) != va {
			return 'VAL_ (value table) differs at raw ${k}'
		}
	}
	return ''
}

// check_frame_route_contract enforces REQ-TOPO-007: a raw frame forward is valid
// ONLY when the two buses agree on the frame's COMPLETE wire meaning. It resolves
// the frame in BOTH buses' DBCs and compares id, dlc, format (classic/standard —
// FD and extended-id are rejected until the driver Frame carries those flags, P2c),
// and every signal's bit layout / scaling / sign / endianness / multiplexing / unit
// / value table. Any mismatch is an error telling the author to use a signal route
// (which re-encodes) — a differing (or protected) frame is never raw-forwarded.
fn check_frame_route_contract(s System, r Route) []Issue {
	mut issues := []Issue{}
	from := s.bus_by_name(r.from) or { return issues } // structural checks already flagged it
	to := s.bus_by_name(r.to) or { return issues }
	src_db := route_load_bus_dbc(s, r, from, 'source') or {
		return [Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      'frame route on "${r.gateway}" ("${r.frame}"): ${err}'
		}]
	}
	dst_db := route_load_bus_dbc(s, r, to, 'destination') or {
		return [Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      'frame route on "${r.gateway}" ("${r.frame}"): ${err}'
		}]
	}
	sm := route_msg_of(src_db, r.frame) or {
		return [Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      'frame route on "${r.gateway}": frame "${r.frame}" is not defined in source bus "${r.from}" DBC "${from.dbc}"'
		}]
	}
	dm := route_msg_of(dst_db, r.frame) or {
		return [Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      'frame route on "${r.gateway}": frame "${r.frame}" is not defined in destination bus "${r.to}" DBC "${to.dbc}" — a raw frame forward requires both buses to define the frame identically (else use a signal route)'
		}]
	}
	pre := 'frame route on "${r.gateway}" ("${r.frame}", ${r.from} -> ${r.to}):'
	// format: a raw forward carries the id WIDTH unchanged, so both frames must share it
	// — both standard or both extended (the driver Frame now carries an ext flag, and the
	// forwarder copies it). A std<->ext mismatch can't be raw-forwarded (use a signal
	// route). CAN-FD and RTR remain a later Frame-format increment (rejected below / RTR
	// dropped by the driver). A routed frame is expected to be a periodic data PDU.
	if sm.ext != dm.ext {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} id width differs (extended ${sm.ext} on "${r.from}" vs ${dm.ext} on "${r.to}") — a raw forward cannot change standard<->extended; use a signal route'
		}
	}
	// an id above the 11-bit standard range is only valid as an EXTENDED frame; an
	// UNFLAGGED id > 0x7ff is malformed (a standard-id send would truncate/reject it).
	if (sm.id > 0x7ff && !sm.ext) || (dm.id > 0x7ff && !dm.ext) {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} id 0x${sm.id.hex()}/0x${dm.id.hex()} is above the 11-bit standard range but not marked extended — malformed'
		}
	}
	if sm.dlc > 8 || dm.dlc > 8 {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} CAN-FD (dlc > 8) frames are not raw-forwarded yet (P2c) — the driver frame path does not carry the fd flag'
		}
	}
	// FD buses can't be raw-forwarded yet — on either side. driver.can.Channel.send
	// always emits a canfd_frame on an FD destination, an FD receive socket accepts
	// BOTH classic and FD frames, and can.Frame discards which format (and BRS) it
	// received — so even a matched fd=true/fd=true pair can silently reframe a classic
	// PDU as FD. Until Frame carries the received format (P2c), reject any FD bus.
	if from.fd || to.fd {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} a bus is CAN-FD (compute fd=${from.fd}, edge fd=${to.fd}) — raw forwarding cannot preserve the frame format yet (P2c); a signal route re-encodes'
		}
	}
	// PROTECTION (E2E/SecOC) is authored ONLY in a node\'s ecu.toml [[frame]] e2e/secoc
	// block — never in the DBC or system.toml. A dissolved node partial that authors
	// ANY [[frame]] is REJECTED upstream (checks.v, "a [[frame]]" in the authored-in-a-
	// partial gate), so a protected frame cannot even be declared as a dissolution frame
	// route: it is rejected before reaching this compare. There is thus no protection
	// metadata to compare here. A protected frame must be a SIGNAL route (its dest
	// producer re-protects); P2c adds E2E-reprotect for a routed frame.
	// cadence: a raw forward re-emits at the SOURCE rate (on receipt), so the two buses
	// must agree on the frame's cycle time. It must also be CYCLIC (cycle_ms > 0): the
	// forwarder holds one PDU per destination and, under tx backpressure, keeps the
	// freshest (rate adaptation of a periodic frame) rather than blocking the source
	// receive path. An EVENT frame (cycle_ms == 0) can't tolerate that sampling — every
	// event matters — so it needs a signal route (or P2c's buffered delivery).
	if sm.cycle_ms == 0 || dm.cycle_ms == 0 {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} frame is not cyclic (GenMsgCycleTime ${sm.cycle_ms}/${dm.cycle_ms}) — a raw forward samples the freshest PDU under backpressure, which drops events; an event frame needs a signal route'
		}
	} else if sm.cycle_ms != dm.cycle_ms {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} cadence differs (${sm.cycle_ms} ms vs ${dm.cycle_ms} ms) — a raw forward keeps the source rate; a differing cadence needs a signal route'
		}
	} else if sm.cycle_ms < 10 {
		// the comm bridge ticks every 10 ms; a sub-tick cadence can't be honored (the
		// forwarder would burst-drain several source periods) — mirror the signal-route
		// guard (dbc.v cadence-below-tick check).
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} cadence ${sm.cycle_ms} ms is below the 10 ms comm-bridge tick — a raw forward cannot preserve a sub-tick rate'
		}
	}
	// the gateway becomes the on-wire transmitter of the frame on `to`. If the dest
	// DBC names a DIFFERENT BO_ transmitter, that node also sends the PDU — reject the
	// second writer (mirror the signal-route sender check; a placeholder is fine).
	if dm.sender != '' && !dm.sender.starts_with('Vector__') && dm.sender != r.gateway {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-012'
			msg:      '${pre} destination DBC names "${dm.sender}" as the transmitter of "${r.frame}", not the gateway — the forward would be a second on-wire writer'
		}
	}
	// wire shape must AGREE across the two buses (id, dlc), else the PDU means
	// something different on the destination and must be re-encoded (a signal route).
	if sm.id != dm.id {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} CAN id differs (0x${sm.id.hex()} on "${r.from}" vs 0x${dm.id.hex()} on "${r.to}") — a raw forward keeps the id; use a signal route to re-frame'
		}
	}
	if sm.dlc != dm.dlc {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} DLC differs (${sm.dlc} vs ${dm.dlc}) — the payload layout cannot match'
		}
	}
	// MULTIPLEXING is unsupported for raw forwarding: candb does not parse SG_MUL_VAL_
	// (extended-mux selector ranges), so two frames could match on the basic mux fields
	// yet activate a signal for different selectors. Reject any multiplexed frame — its
	// presence semantics can't be fully verified (a signal route decodes explicitly).
	for m in [sm, dm] {
		for sg in m.signals {
			if sg.is_multiplexor || sg.is_multiplexed {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-007'
					msg:      '${pre} frame is multiplexed (signal "${sg.name}") — multiplexing is not raw-forwarded (candb does not model SG_MUL_VAL_); use a signal route'
				}
				break
			}
		}
	}
	// DUPLICATE SG_ names would make the name-keyed comparison below match one-to-many
	// (a source signal could match the wrong destination occurrence). candb accepts them,
	// so reject a frame with a repeated signal name rather than compare ambiguously.
	for m in [sm, dm] {
		mut seen := map[string]bool{}
		for sg in m.signals {
			if sg.name in seen {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-007'
					msg:      '${pre} frame declares signal "${sg.name}" more than once — an ambiguous contract; a raw route needs uniquely-named signals'
				}
			}
			seen[sg.name] = true
		}
	}
	// every signal must be present on both sides with an identical wire contract.
	if sm.signals.len != dm.signals.len {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-007'
			msg:      '${pre} signal count differs (${sm.signals.len} vs ${dm.signals.len}) — use a signal route'
		}
	}
	for a in sm.signals {
		mut found := false
		for b in dm.signals {
			if b.name == a.name {
				found = true
				diff := sig_wire_diff(a, b)
				if diff != '' {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-007'
						msg:      '${pre} signal "${a.name}" ${diff} between buses — a raw forward carries the PDU unchanged; a differing contract needs a signal route'
					}
				}
				break
			}
		}
		if !found {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-007'
				msg:      '${pre} signal "${a.name}" is on "${r.from}" but not in the same frame on "${r.to}" — use a signal route'
			}
		}
	}
	return issues
}

pub fn check_route_dbc(s System) []Issue {
	mut issues := []Issue{}
	// all signal routes composing ONE destination frame must share a source bus (each
	// source bridge composes independently) — track the first source bus per dest frame.
	mut frame_src := map[string]string{}
	for r in s.routes {
		if r.to == '' {
			continue
		}
		// FRAME (raw-PDU) route: the PDU is carried UNCHANGED, so a raw forward is
		// valid only when both buses define the frame with an IDENTICAL wire contract
		// (REQ-TOPO-007). Any mismatch must translate — a signal route — instead.
		if r.frame != '' {
			issues << check_frame_route_contract(s, r)
			continue
		}
		if r.signal == '' {
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
		mut nmatch := 0
		for m in db.messages {
			for sg in m.signals {
				if sg.name == r.signal {
					dsg = sg
					dmsg = m
					sender = m.sender
					nmatch++
					break
				}
			}
		}
		// ambiguous (>1 frame): report HERE too — sysgen's frame_of_signal rejects it,
		// so the validation gate must too (else syscheck says OK, sysgen then fails).
		if nmatch > 1 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": signal "${r.signal}" appears in ${nmatch} frames in destination DBC "${to.dbc}" (bus "${r.to}") — the destination frame is ambiguous'
			}
			continue
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
		// the routed producer re-emits per the dest cadence, but the comm bridge ticks
		// at 10 ms — a sub-tick DBC cadence can't be honored (loom2v panics; mirror it).
		if dm.cycle_ms > 0 && dm.cycle_ms < 10 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": destination frame "${dm.name}" cadence ${dm.cycle_ms} ms is below the 10 ms comm-bridge tick — cannot re-emit that fast'
			}
		}
		// same-source-bus composition (mirror loom2v): every route into this dest frame
		// must originate on ONE source bus, else the frame ships two half-populated copies.
		fkey := '${r.to}/${dm.name}'
		if prev := frame_src[fkey] {
			if prev != r.from {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'route on "${r.gateway}": destination frame "${dm.name}" on "${r.to}" is composed from two source buses ("${prev}" and "${r.from}") — a routed frame\'s signals must share one source bus'
				}
			}
		} else {
			frame_src[fkey] = r.from
		}
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
		// P2a.2b transcodes SCALE (factor/offset/width) — so the source and dest SG_ may
		// differ there — but a route carries a NUMBER, so UNITS, VAL_ enum meaning, and
		// physical RANGE must be preserved across the two buses' DBCs. Compare the source
		// SG_ (in the FROM bus's DBC) against the dest SG_ ds.
		if from := s.bus_by_name(r.from) {
			if from.dbc != '' {
				fpath := if os.is_abs_path(from.dbc) { from.dbc } else { os.join_path(s.dir, from.dbc) }
				if fdb := candb.load_dbc_file(fpath) {
					mut ssg := ?candb.Signal(none)
					for fm in fdb.messages {
						for sg in fm.signals {
							if sg.name == r.signal {
								ssg = sg
								break
							}
						}
					}
					if src := ssg {
						// the route carries the PHYSICAL value through f64 (to transcode),
						// exact only to 52 bits — same limit loom2v enforces standalone.
						if src.length > 52 || ds.length > 52 {
							issues << Issue{
								severity: .error
								req:      'REQ-TOPO-003'
								msg:      'route on "${r.gateway}": signal "${r.signal}" is >52 bits — the route carries the physical value through f64 (exact only to 52-bit integers)'
							}
						}
						if src.unit != ds.unit {
							issues << Issue{
								severity: .error
								req:      'REQ-TOPO-003'
								msg:      'route on "${r.gateway}": signal "${r.signal}" unit "${src.unit}" (source) != "${ds.unit}" (destination) — the route transcodes scale, not units'
							}
						}
						if !route_val_phys_equal(src, ds) {
							issues << Issue{
								severity: .error
								req:      'REQ-TOPO-003'
								msg:      'route on "${r.gateway}": signal "${r.signal}" source and destination VAL_ tables differ (at equal physical values) — the route does not translate enum meanings'
							}
						}
						slo, shi := route_phys_range(src)
						dlo, dhi := route_phys_range(ds)
						if slo < dlo || shi > dhi {
							issues << Issue{
								severity: .error
								req:      'REQ-TOPO-003'
								msg:      'route on "${r.gateway}": signal "${r.signal}" source range [${slo}, ${shi}] does not fit the destination range [${dlo}, ${dhi}] — the re-encode would overflow'
							}
						}
					}
				}
			}
		}
		// the dissolution codec re-encodes trivial LITTLE-ENDIAN signals; a big-endian
		// (Motorola) destination SG_ has a sawtooth bit layout the generated encoder
		// does not produce, so reject it rather than approximate its span.
		if ds.byte_order != .little_endian {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": destination DBC SG_ "${r.signal}" (bus "${r.to}") is big-endian (Motorola) — the dissolution codec re-encodes little-endian signals only'
			}
		} else {
			// its OCCUPIED bit range must fit the destination frame's payload — not just
			// its width. A little-endian SG_ occupies [start_bit, start_bit+length); one
			// starting near the end (e.g. 56|16 in an 8-byte frame) overflows the DLC and
			// is truncated on the wire even though its width alone fits.
			payload_bits := dm.dlc * 8
			occupied := ds.start_bit + ds.length
			if occupied > payload_bits {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'route on "${r.gateway}": signal "${r.signal}" occupies up to bit ${occupied} but destination frame "${dm.name}" is only ${dm.dlc} bytes (${payload_bits} bits) on bus "${r.to}"'
				}
			}
		}
		// the destination FRAME must be sendable on the destination bus: a classic
		// (non-FD) bus caps the DLC at 8, and an extended-id frame has no format flag
		// in can.Frame (it would ship as a standard id).
		if !to.fd && dm.dlc > 8 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'route on "${r.gateway}": destination frame "${dm.name}" is ${dm.dlc} bytes but bus "${r.to}" is classic (fd = false, DLC <= 8)'
			}
		}
		// (an extended-id destination is now supported: the gateway's COM producer
		//  composes the frame and the driver sends it with Frame.ext = true — emb#180/#181,
		//  same path the standalone loom2v signal route uses.)
		// the WHOLE destination frame is composed by the gateway's COM producer. A P2a
		// gateway can't produce its own signals, so every OTHER SG_ in the frame must
		// be filled by another route from the SAME gateway — else the producer emits a
		// partially-populated PDU.
		for sg in dm.signals {
			if sg.name == r.signal {
				continue
			}
			mut covered := false
			for r2 in s.routes {
				if r2.gateway == r.gateway && r2.to == r.to && r2.signal == sg.name {
					covered = true
					break
				}
			}
			if !covered {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'route on "${r.gateway}": destination frame "${dm.name}" (bus "${r.to}") also carries SG_ "${sg.name}", which no route from "${r.gateway}" fills — the frame would be partially populated'
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
	mut kind_of := map[string]string{}
	mut has_service := map[string]bool{}
	for bus in s.buses {
		has_dbc[bus.name] = bus.dbc != ''
		kind_of[bus.name] = bus.kind
		has_service[bus.name] = bus.service != 0
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
		// key by id AND width: a standard and an extended frame with the same numeric
		// id are distinct on the wire (recv reports the width), so only a same-id/width
		// pair is a real one-frame-per-id clash.
		mut id_seen := map[string]string{}
		for msg in dbs[bus.name].messages {
			key := '${msg.id}/${msg.ext}'
			if prev := id_seen[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'bus "${bus.name}": DBC frames "${prev}" and "${msg.name}" share CAN id 0x${msg.id.hex()} (${if msg.ext { 'extended' } else { 'standard' }}) — one frame per id'
				}
			} else {
				id_seen[key] = msg.name
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
			// NM peers are standard 11-bit; the NM receiver requires !rx.ext, so an
			// extended frame with a stripped id in the range is distinct on the wire.
			if !msg.ext && msg.id >= bus.nm_peers_lo && msg.id <= bus.nm_peers_hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'bus "${bus.name}": DBC frame "${msg.name}" id 0x${msg.id.hex()} falls in the NM peer range [0x${bus.nm_peers_lo.hex()},0x${bus.nm_peers_hi.hex()}] — application ids must not overlap NM'
				}
			}
		}
	}
	for sig in s.signals {
		// the CARRIER decides the contract a signal conforms to. A someip bus carries
		// the signal on an EVENT of its service — there is no DBC frame to conform to,
		// so requiring one here would reject every SOME/IP signal bus outright. What it
		// needs instead is the service the events ride (REQ-TOPO-003).
		if (kind_of[sig.bus] or { 'can' }) == 'someip' {
			if !(has_service[sig.bus] or { false }) {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-003'
					msg:      'signal "${sig.name}": someip bus "${sig.bus}" carries cross-node signals but declares no `service` — a SOME/IP event needs the service it belongs to'
				}
			}
			continue
		}
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
