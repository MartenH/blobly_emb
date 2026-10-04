module main

// The CAN receive path — ONE set of templates for both owners of a bus: the host COM bridge
// (emit_bridges) and the ThreadX comm thread (emit_run_target). A received frame is checked by its
// protections (comm/secoc, comm/e2e), judged by com.RxMonitor (its deadlines, E2E's receive rule,
// a commanded silence), and its signals are published with what the monitor answered; the
// signal-status faults step on every publication. Only RxOwner differs between the two owners.

// RxOwner is what an owner of a bus's receive path supplies.
struct RxOwner {
	fmem    string // the fault memory the signal-status faults report into
	rx_on   string // UDS 0x28 has reception on — '' where no diagnostic server can switch it
	awake   string // the network awake — '' without NM
	faults  bool // this bus hosts the node's signal-status faults
	publish fn(si SigInfo, fld string) string @[required] // the publication of signal value `fld` ('' = none)
}

// gated: the owner keeps a reception gate (com.RxGate) for this bus.
fn (o RxOwner) gated() bool {
	return o.rx_on != '' || o.awake != ''
}

// on: the gate a publication waits on (reception on).
fn (o RxOwner) on() string {
	return if o.gated() { 'st.rxg.on' } else { 'true' }
}

// suspended: a silence is latched whose restart has not run.
fn (o RxOwner) suspended() string {
	return if o.gated() { 'st.rxg.suspended()' } else { 'false' }
}

// live: a deadline may fire and a level be judged.
fn (o RxOwner) live() string {
	return if o.gated() { 'st.rxg.live()' } else { 'true' }
}

// rx_monitored: the frame has a com.RxMonitor — a deadline to keep, or a protection whose verdict
// the monitor turns into a status.
fn rx_monitored(m Model, msg string, bname string) bool {
	return has_deadline(m, msg, bname) || m.frames.e2e_here(msg, bname) || m.frames.secoc_here(msg, bname)
}

// rx_state_fields: the owner state of the received frames `msgs` on `bname` — a monitor per
// monitored frame, SecOC's key and freshness, the reception gate.
fn rx_state_fields(m Model, msgs []string, bname string, owner RxOwner) []string {
	mut out := []string{}
	for msg in msgs {
		if rx_monitored(m, msg, bname) {
			out << '\trxm_${msg} com.RxMonitor // its deadlines, E2E receive state and silences (comm/com)'
		}
		if m.frames.secoc_here(msg, bname) {
			out << '\tsecoc_key_${msg} secoc.Key'
			out << '\tsecoc_rx_${msg} secoc.RxState'
		}
	}
	if owner.gated() {
		out << '\trxg com.RxGate // reception: UDS 0x28 on, the network awake'
	}
	return out
}

// signal_fault_fields: the state signal-status faults keep on the owner of the fault memory.
fn signal_fault_fields(m Model) []string {
	mut out := []string{}
	for src in fault_sources(m) {
		out << "\tfsrc_${snake(src)} sig.RxStatus // ${src}'s latest published status (signal-status faults)"
	}
	for i, f in m.faults {
		if f.signal == '' {
			continue
		}
		out << '\tsdeb_${i} fault.Debounce // ${f.name}: ${f.signal} ${f.on}, debounced here'
		out << '\tsev_${i} bool // a publication stepped it since the last pass top: skip the level step'
		if f.on == 'lost' {
			lt := (m.sig_of[f.signal] or { SigInfo{} }).lost_type
			out << '\tslost_${i} ${lt} // the lost-frame count last seen (wrapping)'
		}
	}
	return out
}

// signal_fault_init: each signal-status fault's debouncer, configured at the owner's start.
fn signal_fault_init(m Model, ind string) []string {
	mut out := []string{}
	for i, f in m.faults {
		if f.signal == '' {
			continue
		}
		out << '${ind}st.sdeb_${i} = fault.Debounce{'
		if f.time_based {
			out << '${ind}\ttime_based: true'
		}
		out << '${ind}\tfail_thr: ${f.fail_thr}'
		out << '${ind}\tpass_thr: ${f.pass_thr}'
		out << debounce_step_lines(f, ind + '\t')
		out << '${ind}}'
	}
	return out
}

// rx_state_init: the monitors' deadlines, armed from the owner's start (a sender absent since
// boot still reaches `timeout`, docs/diagnostics.md §7), and SecOC's keys.
fn rx_state_init(m Model, msgs []string, bname string, now string, ind string) []string {
	mut out := []string{}
	for msg in msgs {
		if rx_monitored(m, msg, bname) {
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				out << '${ind}st.rxm_${msg}.com.timeout_us = ${m.frames.rx_timeout_us[msg]}'
			}
			if e2e_timeout(m, msg, bname) > 0 {
				out << '${ind}st.rxm_${msg}.e2e.timeout_us = ${e2e_timeout(m, msg, bname)}'
			}
			out << '${ind}st.rxm_${msg}.start(${now})'
		}
		if m.frames.secoc_here(msg, bname) {
			out << '${ind}st.secoc_key_${msg} = secoc.new_key(${byte16_lit(m.frames.secoc_key[msg] or {
				[]u8{}
			})})'
		}
	}
	return out
}

// rx_gate_lines: a sampling of the reception gate — at the top of a pass, after a request served
// inside the drain, and after the pass's requests. Whenever it finds the bus silent the silence
// is latched (com.RxGate), each E2E frame's next gap is marked commanded, and a watched signal's
// status goes stale — reset HERE, never after the drain, so a publication after the re-enable is
// not overwritten.
fn rx_gate_lines(m Model, msgs []string, bname string, owner RxOwner, ind string) []string {
	if !owner.gated() {
		return []string{}
	}
	rx_on := if owner.rx_on != '' { owner.rx_on } else { 'true' }
	awake := if owner.awake != '' { owner.awake } else { 'true' }
	call := 'st.rxg.sample(${rx_on}, ${awake})'
	mut quiet := []string{}
	for msg in msgs {
		if m.frames.e2e_here(msg, bname) {
			quiet << '${ind}\tst.rxm_${msg}.silenced()'
		}
	}
	if owner.faults {
		for src in fault_sources(m) {
			quiet << '${ind}\tst.fsrc_${snake(src)} = .never_received'
		}
	}
	if quiet.len == 0 {
		return ['${ind}${call}']
	}
	mut out := ['${ind}if ${call} { // silent: latch it, frame or not']
	out << quiet
	out << '${ind}}'
	return out
}

// rx_frame_arm: one received frame's branch of the drain — its protections checked, the monitor's
// answer, its signals published. The received length must be the frame's DLC: recv copies only the
// bytes that arrived into the reused frame, so a short same-id frame would decode stale bytes.
fn rx_frame_arm(m Model, msg string, list []string, ext bool, bname string, owner RxOwner, ind string) []string {
	mut out := [
		'${ind}if rx.id == ${msg}_id && rx.len == ${msg}_dlc && rx.ext == ${ext} {',
	]
	i := ind + '\t'
	if !rx_monitored(m, msg, bname) {
		mut body := rx_publish_block(m, msg, bname, list, '', 'ok', true, owner, if owner.gated() {
			i + '\t'
		} else {
			i
		})
		if owner.gated() {
			out << '${i}if st.rxg.on {'
			out << body
			out << '${i}}'
		} else {
			out << body
		}
		out << '${ind}}'
		return out
	}
	p := 'p_${msg}'
	on := owner.on()
	e2e_on := m.frames.e2e_here(msg, bname)
	secoc_on := m.frames.secoc_here(msg, bname)
	e2e_args := '&rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or { 0 }).hex()}), ${m.frames.e2e_crc[msg] or {
		0
	}}, ${m.frames.e2e_ctr[msg] or { 0 }}'
	// the E2E check of an authentic frame (REQ-E2E-004: SecOC first, and E2E leaves SecOC's bytes out)
	chk := if secoc_on {
		'st.rxm_${msg}.e2e.check_ex(${e2e_args}, ${m.frames.secoc_fresh[msg] or { 0 }}, 1, ${m.frames.secoc_mac[msg] or {
			0
		}}, ${m.frames.secoc_maclen[msg] or { 0 }})'
	} else {
		'st.rxm_${msg}.e2e.check(${e2e_args})'
	}
	accept := if e2e_on {
		'st.rxm_${msg}.checked(now, chk_${msg}, ${on}, ${owner.suspended()})'
	} else {
		'st.rxm_${msg}.received(now, ${on})'
	}
	if secoc_on {
		verify := 'st.secoc_rx_${msg}.verify(&st.secoc_key_${msg}, &rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.secoc_id[msg] or {
			0
		}).hex()}), ${m.frames.secoc_fresh[msg] or { 0 }}, ${m.frames.secoc_mac[msg] or { 0 }}, ${m.frames.secoc_maclen[msg] or {
			0
		}})'
		out << '${i}mut ${p} := com.RxPublish.none'
		out << '${i}if ${verify}.usable() {'
		if e2e_on {
			out << '${i}\tchk_${msg} := ${chk}'
		}
		out << '${i}\t${p} = ${accept}'
		out << '${i}} else {'
		out << '${i}\t${p} = st.rxm_${msg}.rejected(now, ${on}) // SecOC refused it'
		out << '${i}}'
	} else {
		if e2e_on {
			out << '${i}chk_${msg} := ${chk}'
		}
		out << '${i}${p} := ${accept}'
	}
	out << rx_publish_block(m, msg, bname, list, p, '', true, owner, i)
	out << '${ind}}'
	return out
}

// rx_publish_block: the publication of a frame's signals, with what com.RxMonitor answered in the
// variable `p` — or, with p = '', the fixed status `fixed` ('ok' / 'timeout'). A signal's value is
// decoded only from a good frame (`decode` = a received frame is in scope); a timeout or an
// integrity failure publishes the status with the value withheld, and an integrity failure
// publishes nothing to a signal that has no status to carry it.
fn rx_publish_block(m Model, msg string, bname string, list []string, p string, fixed string, decode bool, owner RxOwner, ind string) []string {
	mut out := []string{}
	mut i := ind
	// only a protected frame can fail its check
	integ := p != '' && (m.frames.e2e_here(msg, bname) || m.frames.secoc_here(msg, bname))
	if p != '' {
		out << '${i}if ${p} != .none {'
		i += '\t'
	}
	for sname in list {
		si := m.sig_of[sname] or { continue }
		fld := snake(sname)
		dec := '${msg}_${fld}_phys(rx.data)'
		val := if si.val_type == 'bool' { '${dec} != 0.0' } else { '${si.val_type}(${dec})' }
		out << '${i}mut ${fld} := sig.${sname}{}'
		if decode && si.val_field != '' {
			if p != '' {
				out << '${i}if ${p} == .ok {'
				out << '${i}\t${fld}.${si.val_field} = ${val}'
				out << '${i}}'
			} else if fixed == 'ok' {
				out << '${i}${fld}.${si.val_field} = ${val}'
			}
		}
		if si.has_status {
			st := if p != '' { 'rx_status_of(${p})' } else { '.${fixed}' }
			out << '${i}${fld}.status = ${st}'
		}
		if si.lost_type != '' && m.frames.e2e_here(msg, si.bus) {
			out << '${i}${fld}.lost = ${si.lost_type}(st.rxm_${msg}.lost())'
		}
		pl := owner.publish(si, fld)
		if pl == '' {
			continue
		}
		if !si.has_status && integ {
			out << '${i}if ${p} != .integrity {'
			out << '${i}\t${pl}'
			out << '${i}}'
		} else {
			out << '${i}${pl}'
		}
	}
	guard := if integ { '${p} != .integrity && ' } else { '' }
	out << rx_group_hooks(m, list, owner, guard, i)
	if p != '' {
		out << '${ind}}'
	}
	return out
}

// rx_settle_lines: the pass's end for the frames `msgs` — the gate re-sampled after the pass's
// requests were served (a 0x28 answered now suspends the deadlines before any can fire), every
// deadline restarted when reception has come back, and each deadline polled: one silence, one
// `timeout`, whichever of the COM deadline (REQ-COM-005) and E2E's own (REQ-E2E-002) saw it.
fn rx_settle_lines(m Model, msgs []string, list_of map[string][]string, bname string, owner RxOwner, ind string) []string {
	mut out := []string{}
	if owner.gated() {
		out << rx_gate_lines(m, msgs, bname, owner, ind)
		mon := msgs.filter(rx_monitored(m, it, bname))
		if mon.len > 0 {
			out << '${ind}if st.rxg.settle() { // reception is back: every deadline runs from now'
			for msg in mon {
				out << '${ind}\tst.rxm_${msg}.restart(now)'
			}
			out << '${ind}}'
		} else {
			out << '${ind}st.rxg.settle()'
		}
	}
	for msg in msgs {
		if !has_deadline(m, msg, bname) {
			continue
		}
		live := if owner.gated() { '${owner.live()} && ' } else { '' }
		out << '${ind}if ${live}st.rxm_${msg}.expire(now) {'
		out << rx_publish_block(m, msg, bname, list_of[msg] or { []string{} }, '', 'timeout', false, owner, ind + '\t')
		out << '${ind}}'
	}
	return out
}

// rx_status_fn: RxPublish -> the generated RxStatus, emitted once where a monitored frame carries a
// status (the two enums share their order: never_received ok timeout integrity).
fn rx_status_fn() []string {
	return [
		'',
		'// rx_status_of: what com.RxMonitor answered, as the signal status it publishes',
		'fn rx_status_of(p com.RxPublish) sig.RxStatus {',
		'\treturn match p {',
		'\t\t.none { .never_received }',
		'\t\t.ok { .ok }',
		'\t\t.timeout { .timeout }',
		'\t\t.integrity { .integrity }',
		'\t}',
		'}',
	]
}

// rx_publish_hooks: what a signal-status fault needs from EVERY publication of a signal it
// watches — a good decode, a deadline or E2E timeout, an integrity failure, a late frame — in one
// place, so no publish path can be missed. Each publication IS a test result (failed, passed, or
// not tested), stepped and consumed right here, so it lands on the correct side of every boundary
// inside the drain: a cycle edge, a clear, a 0x28 switching reception. The pass top only steps
// the level for a pass with no publication (a timeout holding, a sender gone quiet).
fn rx_publish_hooks(m Model, sname string, fld string, owner RxOwner, ind string) []string {
	if !owner.faults || sname !in fault_sources(m) {
		return []string{}
	}
	fm := owner.fmem
	mut out := []string{}
	out << '${ind}st.fsrc_${snake(sname)} = ${fld}.status'
	for i, f in m.faults {
		if f.signal != sname {
			continue
		}
		res := match f.on {
			'timeout', 'integrity' {
				'if ${fld}.status == .${f.on} { fault.TestResult.failed } else if ${fld}.status == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
			else {
				// the count wraps in its own type: a gap is a small forward step, modulo
				lt := (m.sig_of[f.signal] or { SigInfo{} }).lost_type
				half := match lt {
					'u8' { '0x80' }
					'u16' { '0x8000' }
					else { '0x8000_0000' }
				}
				d := '${lt}(${fld}.lost - st.slost_${i})'
				'if ${d} != 0 && ${d} < ${half} { fault.TestResult.failed } else if ${fld}.status == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
		}
		out << '${ind}st.sdeb_${i}.apply(${fm}.control_gen(${i}), ${fm}.control_held(${i}))'
		out << '${ind}st.sdeb_${i}.step(${res}, now, ${owner.on()})'
		out << '${ind}${fm}.consume(${i}, st.sdeb_${i}.rep)'
		out << '${ind}st.sev_${i} = true'
		if f.on == 'lost' {
			out << '${ind}st.slost_${i} = ${fld}.lost'
		}
	}
	return out
}

// rx_group_hooks: the fault memory's share of one publication group (the signals one frame, one
// deadline or one integrity failure publishes together), after all of them are published. The
// operation cycle moves where its signal is published, in bus order (an off/on pair in one drain
// is two edges): a RISING edge before the group's results and a FALLING one after them, so a
// frame that starts or ends the cycle and also carries a result (a gap, its own timeout) records
// that result inside the cycle either way. `guard` prefixes the cycle edges: a cycle signal with
// no status is not published by an integrity failure, so it moves no cycle then.
fn rx_group_hooks(m Model, list []string, owner RxOwner, guard string, ind string) []string {
	mut out := []string{}
	if m.faults.len == 0 || !owner.faults {
		return out
	}
	cyc := m.fault_cycle.all_before('.')
	cf := m.fault_cycle.all_after('.')
	has_cycle := m.fault_cycle != '' && m.fault_cycle != fault_cycle_power && cyc in list
	g := if has_cycle && (m.sig_of[cyc] or { SigInfo{} }).has_status { '' } else { guard }
	fm := owner.fmem
	if has_cycle {
		out << '${ind}if ${g}${snake(cyc)}.${cf} && !st.fcycle_on {'
		out << '${ind}\t${fm}.cycle_start()'
		out << '${ind}\tst.fcycle_on = true'
		out << '${ind}}'
	}
	for sname in list {
		out << rx_publish_hooks(m, sname, snake(sname), owner, ind)
	}
	if has_cycle {
		out << '${ind}if ${g}!${snake(cyc)}.${cf} && st.fcycle_on {'
		out << '${ind}\t${fm}.cycle_end()'
		out << '${ind}\tst.fcycle_on = false'
		out << '${ind}}'
	}
	return out
}

// signal_fault_step_lines: the pass-top step of each signal-status fault — its watched signal's
// LEVEL (the condition still holding, a good status, or not known) — for a pass whose drain
// published nothing (rx_publish_hooks stepped those). While the test is disabled — reception off,
// the network asleep, or a silence whose restart has not run — it always steps, disabled, so a
// time-based run never survives the pause.
fn signal_fault_step_lines(m Model, owner RxOwner, ind string) []string {
	mut out := []string{}
	fm := owner.fmem
	en := owner.live()
	for i, f in m.faults {
		if f.signal == '' {
			continue
		}
		src := 'st.fsrc_${snake(f.signal)}'
		// lost is an event only: its level can pass, never fail
		res := match f.on {
			'timeout', 'integrity' {
				'if ${src} == .${f.on} { fault.TestResult.failed } else if ${src} == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
			else {
				'if ${src} == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
		}
		out << '${ind}if st.sev_${i} && ${en} {'
		out << '${ind}\tst.sev_${i} = false'
		out << '${ind}} else {'
		out << '${ind}\tst.sev_${i} = false'
		out << '${ind}\tst.sdeb_${i}.apply(${fm}.control_gen(${i}), ${fm}.control_held(${i}))'
		out << '${ind}\tst.sdeb_${i}.step(${res}, now, ${en})'
		out << '${ind}\t${fm}.consume(${i}, st.sdeb_${i}.rep)'
		out << '${ind}}'
	}
	return out
}
