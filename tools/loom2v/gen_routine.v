// loom2v's routine codegen (docs/diagnostics.md §3.1 "Routines"): a [[routine]] is a RoutineControl
// (0x31) routine RUN BY AN FB — the handler that reads its `<Name>Request` and writes its
// `<Name>Result` — on that handler's thread, never on the diagnostic server's. comm/uds is the
// runtime (routine.v: the server's side and RoutineFb, the FB's; pending.v: responsePending while
// it runs); this file is its wiring:
//
//   [[routine]]
//   id         = 0x0201
//   name       = "ActuatorSelfTest"
//   mode       = "sync"           # or "async": answered once the FB has accepted it
//   start_in   = 1                # option record bytes a start carries (exactly)
//   start_out  = 2                # record bytes the start's answer carries
//   results    = true             # 0x31 03 offered (results_out bytes)
//   timeout_ms = 10000
//   sessions   = ["extended"]
//   security   = 0
//
// Each routine has two cells, as a fault-owning FB has: the REQUEST cell the server writes (its
// thread reads; a sequence number, the operation, the option record) and the RESULT cell the FB's
// glue writes (the request it answers, the state, an NRC, the record). On a ThreadX target they are
// byte-IOC cells after the fault cells; on the host bridge, triple channels cfg2v allocates
// (routine_req_<name>_ch / routine_res_<name>_ch). The FB sees only `op` and its option record,
// once per request and in the server's order (uds.RoutineFb.take), and writes `state`, `nrc` and
// `record`.
module main

import toml
import boot
import comm.uds
import driver.doipnet
import tools.cfgschema
import tools.ecumodel

// RoutineCfg is one [[routine]].
struct RoutineCfg {
	name        string
	id          int
	async       bool
	stop        bool
	results     bool
	start_in    int
	start_out   int
	results_out int
	timeout_ms  int
	sessions    u8 // uds.in_* mask
	security    int
}

// request / result: the names its FB's handler reads and writes (ecumodel's, the one statement)
fn (r RoutineCfg) request() string {
	return ecumodel.routine_request(r.name)
}

fn (r RoutineCfg) result() string {
	return ecumodel.routine_result(r.name)
}

// record: the bytes of the FB's result record — the start's and 03's answers both read from it
fn (r RoutineCfg) record() int {
	return if r.start_out > r.results_out { r.start_out } else { r.results_out }
}

// routine_keys: the keys a [[routine]] takes — cfgschema's routine table, the one statement
const routine_keys = cfgschema.ecu.table('routine').names()

// the routineIdentifiers a [[routine]] may take: ISO 14229-1 Annex F's vehicle-manufacturer-specific
// (0x0200..0xDFFF) and system-supplier-specific (0xF000..0xFEFF) ranges — every other range has a
// standardised meaning this server does not implement
const routine_id_ranges = [[0x0200, 0xDFFF], [0xF000, 0xFEFF]]

// routine_handler_margin_ms: what a routine's timeout must leave beyond its handler's period — two
// comm passes (at most 10 ticks each), the request reaching the FB and its report coming back
const routine_handler_margin_ms = 20

fn parse_routines(doc toml.Doc) []RoutineCfg {
	mut out := []RoutineCfg{}
	for rv in ecumodel.toml_arr(doc, 'routine') {
		rm := rv.as_map()
		name := (rm['name'] or { toml.Any('') }).string()
		for k, _ in rm {
			if k !in routine_keys {
				panic('loom2v: [[routine]] "${name}" has "${k}" — a routine takes ${routine_keys} (REQ-DIAG-087)')
			}
		}
		id := (rm['id'] or { panic('loom2v: [[routine]] "${name}" needs an `id` (its 16-bit routineIdentifier)') }).i64()
		if !schema_key('routine', 'id').in_range(id) {
			panic('loom2v: [[routine]] "${name}": id 0x${id.hex()} is not a 16-bit routineIdentifier')
		}
		mode := (rm['mode'] or { schema_key('routine', 'mode').default_value() }).string()
		if mode !in schema_key('routine', 'mode').choices {
			panic('loom2v: [[routine]] "${name}": mode "${mode}" is not "sync" or "async"')
		}
		mut sizes := map[string]int{}
		for key in ['start_in', 'start_out', 'results_out', 'timeout_ms', 'security'] {
			sk := schema_key('routine', key)
			v := (rm[key] or { toml.Any(sk.default_int()) }).i64()
			if !sk.in_range(v) {
				panic('loom2v: [[routine]] "${name}": ${key} = ${v} must be ${sk.min}..${sk.max} (REQ-DIAG-087)')
			}
			sizes[key] = int(v)
		}
		mut mask := u8(0)
		for sv in (rm['sessions'] or { schema_key('routine', 'sessions').default_value() }).array() {
			if sv.string() !in schema_key('routine', 'sessions').choices {
				panic('loom2v: [[routine]] "${name}": sessions names "${sv.string()}" — a routine runs in default, extended or safety (programming is the bootloader\'s)')
			}
			mask |= session_bit(sv.string()) or { panic('loom2v: [[routine]] "${name}": ${err}') }
		}
		if mask == 0 {
			panic('loom2v: [[routine]] "${name}": sessions is empty — it could never be started')
		}
		out << RoutineCfg{
			name:        name
			id:          int(id)
			async:       mode == 'async'
			stop:        (rm['stop'] or { schema_key('routine', 'stop').default_value() }).bool()
			results:     (rm['results'] or { schema_key('routine', 'results').default_value() }).bool()
			start_in:    sizes['start_in']
			start_out:   sizes['start_out']
			results_out: sizes['results_out']
			timeout_ms:  sizes['timeout_ms']
			sessions:    mask
			security:    sizes['security']
		}
	}
	return out
}

// routine_fb: the FB that serves routine r (validate_routines made it exactly one)
fn routine_fb(m Model, r RoutineCfg) string {
	return m.routine_fbs[r.name] or { '' }
}

// routine_req_of / routine_res_of: the routine whose request / result `name` is
fn routine_req_of(m Model, name string) ?RoutineCfg {
	for r in m.routines {
		if r.request() == name {
			return r
		}
	}
	return none
}

fn routine_res_of(m Model, name string) ?RoutineCfg {
	for r in m.routines {
		if r.result() == name {
			return r
		}
	}
	return none
}

fn routine_index(m Model, r RoutineCfg) int {
	for i, x in m.routines {
		if x.name == r.name {
			return i
		}
	}
	return -1
}

// validate_routines: everything a [[routine]] needs, refused at generation (REQ-DIAG-087). Returns
// each routine's FB.
fn validate_routines(m Model, doc toml.Doc) map[string]string {
	mut fbs := map[string]string{}
	if m.routines.len == 0 {
		return fbs
	}
	if m.isotp_conns.len != 1 {
		panic('loom2v: [[routine]] needs the node\'s diagnostic server — an [isotp] connection — to serve 0x31 (REQ-DIAG-087)')
	}
	if m.target.on && !m.target.threadx {
		panic('loom2v: [[routine]] on a bare-metal [target] — a routine runs in an FB while the comm thread answers responsePending, which needs ThreadX (REQ-DIAG-087); use kind = "threadx"')
	}
	if m.routines.len > uds.max_routines {
		panic('loom2v: ${m.routines.len} [[routine]]s — a diagnostic server holds at most ${uds.max_routines} (comm/uds max_routines, REQ-DIAG-087)')
	}
	mm := m.isotp_conns[0].max_message
	row, listed := svc_row(m, 0x31)
	if !listed {
		panic('loom2v: [[routine]]: [uds] services leaves out 0x31 — no routine could be started (REQ-DIAG-087)')
	}
	mut scope := ecumodel.snake_scope('[[routine]]')
	mut ids := map[int]string{}
	// the port namespace: a port field is its name snake-cased, so `SelfCHECKRequest` and routine
	// SelfCheck's `SelfCheckRequest` are one field (`self_check_request`) — compared snake-cased
	mut taken := map[string]string{} // snake name -> the name that took it
	for s in m.sig_names {
		taken[ecumodel.snake_name(s)] = s
	}
	for p in m.params {
		taken[ecumodel.snake_name(p.name)] = p.name
	}
	for r in m.routines {
		h := '[[routine]] "${r.name}"'
		if !ecumodel.pascal_ok(r.name) {
			panic('loom2v: ${h}: the name is not PascalCase ([A-Z][A-Za-z0-9]*) — it names the request and result types its FB reads and writes')
		}
		if e := scope.add(r.name) {
			panic('loom2v: ${e} (REQ-DIAG-087)')
		}
		for n in [r.request(), r.result()] {
			sn := ecumodel.snake_name(n)
			if prev := taken[sn] {
				same := if prev == n { '' } else { ' (`${prev}`: both are the port `${sn}`)' }
				panic('loom2v: ${h}: its `${n}` is already a signal, a parameter or another routine\'s${same} — rename one (REQ-DIAG-087)')
			}
			taken[sn] = n
		}
		if m.boot.on && (u16(r.id) == boot.routine_erase || u16(r.id) == boot.routine_check) {
			panic('loom2v: ${h}: id 0x${r.id.hex()} is the bootloader\'s own routine (its erase / check) on this [boot] node (REQ-DIAG-087)')
		}
		if !routine_id_ranges.any(r.id >= it[0] && r.id <= it[1]) {
			panic('loom2v: ${h}: id 0x${r.id:04X} is outside 0x0200..0xDFFF and 0xF000..0xFEFF — the ISO 14229-1 ranges a manufacturer or supplier defines (REQ-DIAG-087)')
		}
		if prev := ids[r.id] {
			panic('loom2v: ${h}: id 0x${r.id:04X} is already "${prev}" — a routineIdentifier is unique per server (REQ-DIAG-087)')
		}
		ids[r.id] = r.name
		if r.stop && !r.async {
			panic('loom2v: ${h}: `stop` on a synchronous routine — its start is answered when it completes, so there is never a running routine to stop; use mode = "async" (REQ-DIAG-087)')
		}
		if r.results_out > 0 && !r.results {
			panic('loom2v: ${h}: results_out = ${r.results_out} but `results` is off — no 0x31 03 would carry them (REQ-DIAG-087)')
		}
		for key, n in {'start_in': r.start_in, 'start_out': r.start_out, 'results_out': r.results_out} {
			if n > uds.max_routine_record {
				panic('loom2v: ${h}: ${key} = ${n} — a routine record holds at most ${uds.max_routine_record} bytes (REQ-DIAG-087)')
			}
		}
		need_req := uds.routine_request_len(r.start_in)
		need_ans := uds.routine_answer_len(r.record())
		if need_req > mm || need_ans > mm {
			panic('loom2v: ${h}: its request (${need_req} bytes) or answer (${need_ans} bytes) is longer than [isotp] max_message = ${mm} (REQ-DIAG-087)')
		}
		if m.doip.on && uds.routine_answer_len(r.start_out) > doipnet.push_max {
			panic('loom2v: ${h}: start_out = ${r.start_out} — on a [doip] node a start\'s answer is pushed over DoIP, ${doipnet.push_max} bytes at most (driver/doipnet push_max): start_out <= ${doipnet.push_max - uds.routine_answer_len(0)} (REQ-DIAG-087)')
		}
		// the gates: its own and the 0x31 row's, which a request passes both of — so what decides is
		// their intersection, the sessions it can actually be started in, and either's level
		eff, level := routine_gate(r, row)
		if eff == 0 {
			panic('loom2v: ${h}: its sessions share none with [uds] services 0x31 — it could never be reached (REQ-DIAG-087)')
		}
		if row.security != 0 && r.security != 0 && int(row.security) != r.security {
			panic('loom2v: ${h} needs security ${r.security}, but [uds] services 0x31 needs ${row.security} — one unlock cannot satisfy both (REQ-DIAG-087)')
		}
		if eff & uds.in_default != 0 && level == 0 {
			panic('loom2v: ${h} can be started from the default session with no 0x27 level — a stray request on a quiet bus must not run a routine; leave the default session out (of the routine or its [uds] services 0x31 row) or name a security level (REQ-DIAG-087)')
		}
		if level != 0 && eff & uds.in_extended == 0 {
			panic('loom2v: ${h} needs security ${level} but the sessions it can be started in (its own and [uds] services 0x31\'s) leave out the extended session, the only one an application server unlocks in — entering another relocks it, so it could never be opened (REQ-DIAG-087)')
		}
		if eff & routine_enterable(m) == 0 {
			panic('loom2v: ${h}: [uds] services gives no way into the sessions it can be started in — no "0x10" row serves a session change from the default session, so the server never leaves it (REQ-DIAG-087)')
		}
		// its FB: one handler reads the request and writes the result; nothing else touches either
		// (ecumodel's rule, which sysmodel refuses a system by too)
		u := ecumodel.routine_use(doc, r.name)
		if why := ecumodel.routine_use_refusal(r.name, u) {
			panic('loom2v: ${why}')
		}
		fb := u.req_readers[0].all_before('.')
		thr := m.part.fb_thread[fb] or { '' }
		part := m.part.thread_part[thr] or { '' }
		if m.part.external[part] or { false } {
			if (m.part.image[part] or { '' }) != '' {
				panic('loom2v: ${h}: ${fb} is on a satellite core (partition "${part}") — a routine run by an FB beside a satellite is not generated yet (REQ-PLACE-013); serve it from an FB on the owner image')
			}
			panic('loom2v: ${h}: ${fb} lives in a hand-written satellite (external = true) — its cells would never be emitted (REQ-PLACE-013)')
		}
		if (m.part.threads_of[part] or { [''] }).len > 1 {
			panic('loom2v: ${h}: ${fb} is in a multi-thread partition ("${part}") — not generated yet; serve it from an FB in a single-thread partition (REQ-DIAG-087)')
		}
		if r.timeout_ms <= u.period_ms + routine_handler_margin_ms {
			panic('loom2v: ${h}: timeout_ms = ${r.timeout_ms} is not above ${u.req_readers[0]}\'s period (${u.period_ms} ms) plus ${routine_handler_margin_ms} ms — every start would time out before its FB could answer (REQ-DIAG-087)')
		}
		fbs[r.name] = fb
	}
	if m.target.threadx {
		if why := iocb_overflow(m) {
			panic('loom2v: [[routine]]: ${why} (REQ-DIAG-087)')
		}
	}
	return fbs
}

// routine_gate: the gate a start of routine r passes — the sessions it can actually be started in,
// its own narrowed by the 0x31 service row's (0 = every session, on either side), and the level it
// needs, its own else the row's (io_gate's rule for a control). The level is the routine's
// `security` on the server (routine_config_lines), so a relock of a level a routine is gated on
// through its row stops it too (comm/uds stop_relocked_routines).
fn routine_gate(r RoutineCfg, row SvcCfg) (u8, int) {
	all := uds.in_default | uds.in_extended | uds.in_safety
	own := if r.sessions == 0 { all } else { r.sessions }
	rs := if row.sessions == 0 { all } else { row.sessions }
	level := if r.security != 0 { r.security } else { int(row.security) }
	return own & rs, level
}

// routine_enterable: the sessions a tester can bring the server into — default (power-on), and
// every other only through 0x10, which must then be served in the default session with no level
// (a level is unlocked only in the extended session, which 0x10 is the way into)
fn routine_enterable(m Model) u8 {
	ten, listed := svc_row(m, 0x10)
	if listed && ten.security == 0 && (ten.sessions == 0 || ten.sessions & uds.in_default != 0) {
		return uds.in_default | uds.in_extended | uds.in_safety
	}
	return uds.in_default
}

// routine_levels: the 0x27 levels the routines' gates name (bit L-1 for level L) — sa_levels' share
fn routine_levels(routines []RoutineCfg) u8 {
	mut mask := u8(0)
	for r in routines {
		if r.security != 0 {
			mask |= u8(1) << (r.security - 1)
		}
	}
	return mask
}

// routine_target_on: the image serves routines on its ThreadX comm thread, through byte-IOC cells
fn routine_target_on(m Model) bool {
	return m.target.threadx && m.routines.len > 0
}

// routine_cell: the byte-IOC channel of routine i's request cell (the comm thread writes) or result
// cell (its FB's thread writes) on a ThreadX image — after the signal and fault cells, two per
// routine in declaration order. The one numbering the FB glue, the comm thread and boot share.
fn routine_cell(m Model, i int, result bool) int {
	return rx_iocb_idx(m).len + 2 * fault_local_fbs(m).len + 2 * i + if result { 1 } else { 0 }
}

// --- emitted fragments ---------------------------------------------------------

// routine_sig_structs: each routine's request and result types in the `sig` module (the FB reads
// one and writes the other, as signals); the module imports comm.uds for their op and state.
fn routine_sig_structs(m Model) []string {
	mut g := []string{}
	for r in m.routines {
		g << ''
		g << '// routine "${r.name}" (0x31, id 0x${r.id:04X}, docs/diagnostics.md §3.1): what the diagnostic'
		g << '// server asks — `op` is .start or .stop in exactly ONE dispatch per request, else .none, in'
		g << '// the order the server wrote them (a stop it issued itself before a start that follows it,'
		g << '// which the server does not wait for: a start can come while the FB is still stopping, and'
		g << '// is then refused with 0x24); `option` is the start\'s option record, valid in that dispatch.'
		g << 'pub struct ${r.request()} {'
		g << 'pub mut:'
		g << '\top uds.RoutineOp'
		if r.start_in > 0 {
			g << '\toption [${r.start_in}]u8'
		}
		g << '}'
		g << ''
		g << '// what the FB reports: write `state` on every dispatch that changes the record (a dispatch'
		g << '// that writes .none changes nothing, the last report stands) and answer every op, a .stop'
		g << '// the server issues itself included; .refused answers `nrc` (0x22 / 0x24 / 0x31 / 0x72) and'
		g << '// leaves the state and record as they were (a refused stop leaves the routine running).'
		if r.record() > 0 {
			g << '// `record`: the start\'s answer carries its first ${r.start_out} bytes, 0x31 03 its first ${r.results_out}.'
		}
		g << 'pub struct ${r.result()} {'
		g << 'pub mut:'
		g << '\tstate uds.RoutineState'
		g << '\tnrc   u8'
		if r.record() > 0 {
			g << '\trecord [${r.record()}]u8'
		}
		g << '}'
	}
	return g
}

// routine_sig_header: `sig`'s import of comm.uds, after its module line, when it carries routines
fn routine_sig_header(m Model, mut signals []string) {
	if m.routines.len > 0 {
		signals.insert(2, ['', 'import comm.uds // the routines\' op and state (docs/diagnostics.md §3.1)'])
	}
}

// routine_port_read / routine_port_write: the In / Out field of a routine's request / result
fn routine_port_read(r RoutineCfg) []string {
	return ['\t// routine "${r.name}" (0x31 0x${r.id:04X}): the request the diagnostic server writes, one op per dispatch',
		'\t${snake(r.request())} sig.${r.request()}']
}

fn routine_port_write(r RoutineCfg) []string {
	return ['\t// routine "${r.name}": its state and record, to the diagnostic server',
		'\t${snake(r.result())} sig.${r.result()}']
}

// routine_state_fields: in the serving FB's thread state, per routine it serves — the request cell
// as last read, and the FB side of the routine (its sequence numbers and the result standing)
fn routine_state_fields(m Model, fb string) []string {
	mut g := []string{}
	for r in m.routines {
		if routine_fb(m, r) != fb {
			continue
		}
		f := snake(r.name)
		g << '\trtq_${f} uds.RoutineRequest // routine "${r.name}": its request cell, as last read'
		g << '\trtf_${f} uds.RoutineFb // ... and its FB side: the request taken, the result standing'
	}
	return g
}

// routine_read_lines: a handler's read of routine r's request — the cell read, the op taken once
// per request, the option record with it
fn routine_read_lines(m Model, r RoutineCfg) []string {
	f := snake(r.name)
	inp := 'inp.${snake(r.request())}'
	mut g := []string{}
	if m.target.threadx {
		g << '\tC.iocb_get(${routine_cell(m, routine_index(m, r), false)}, &st.rtq_${f}) // routine "${r.name}": the request the comm thread wrote'
	} else {
		g << '\tosal.${acquire_fn('triple')}(routine_req_${f}_ch, &st.rtq_${f}, u8(sizeof(st.rtq_${f}))) // routine "${r.name}": the request the bridge wrote'
	}
	g << '\t${inp}.op = st.rtf_${f}.take(&st.rtq_${f})'
	if r.start_in > 0 {
		g << '\tif ${inp}.op != .none {'
		g << '\t\tfor k in 0 .. ${r.start_in} {'
		g << '\t\t\t${inp}.option[k] = st.rtq_${f}.data[k]'
		g << '\t\t}'
		g << '\t}'
	}
	return g
}

// routine_write_lines: after the handler — what it reported stamped with the request it answers,
// its record copied only when it wrote a state (Out is zeroed every dispatch), and the result cell
// published every dispatch, as a fault report is
fn routine_write_lines(m Model, r RoutineCfg) []string {
	f := snake(r.name)
	out := 'outp.${snake(r.result())}'
	mut g := ['\tif st.rtf_${f}.report(${out}.state, ${out}.nrc) {']
	if r.record() > 0 {
		g << '\t\tfor k in 0 .. ${r.record()} {'
		g << '\t\t\tst.rtf_${f}.res.data[k] = ${out}.record[k]'
		g << '\t\t}'
	} else {
		g << '\t\t// no record'
	}
	g << '\t}'
	if m.target.threadx {
		g << '\tC.iocb_pub(${routine_cell(m, routine_index(m, r), true)}, &st.rtf_${f}.res) // routine "${r.name}": to the comm thread'
	} else {
		g << '\tosal.${publish_fn('triple')}(routine_res_${f}_ch, &st.rtf_${f}.res, u8(sizeof(st.rtf_${f}.res))) // routine "${r.name}": to the bridge'
	}
	return g
}

// routine_config_lines: the routines configured on server `srv` (conn_init_lines)
fn routine_config_lines(m Model, srv string) []string {
	mut g := []string{}
	row, _ := svc_row(m, 0x31)
	for i, r in m.routines {
		_, level := routine_gate(r, row)
		g << '\t${srv}.routines[${i}] = uds.Routine{ // "${r.name}" (docs/diagnostics.md §3.1)'
		g << '\t\tid:          u16(0x${r.id:04X})'
		g << '\t\tsessions:    u8(0x${r.sessions.hex()})'
		if level != 0 {
			g << '\t\tsecurity:    u8(${level})'
		}
		if r.async {
			g << '\t\tasync:       true'
		}
		if r.stop {
			g << '\t\tstop:        true'
		}
		if r.results {
			g << '\t\tresults:     true'
		}
		if r.start_in > 0 {
			g << '\t\tstart_in:    ${r.start_in}'
		}
		if r.start_out > 0 {
			g << '\t\tstart_out:   ${r.start_out}'
		}
		if r.results_out > 0 {
			g << '\t\tresults_out: ${r.results_out}'
		}
		g << '\t\ttimeout_us:  u64(${r.timeout_ms}) * 1000'
		g << '\t}'
	}
	if m.routines.len > 0 {
		g << '\t${srv}.nroutines = ${m.routines.len}'
	}
	return g
}

// routine_target_results: the routines' share of the comm-thread pass's `.housekeep`, BEFORE the
// connection's housekeeping — each FB's latest report read into the server, so a result the FB
// published before a routine's deadline is in its cell when the server's tick judges that deadline
// (comm/uds pending.v)
fn routine_target_results(m Model) []string {
	if !routine_target_on(m) {
		return []string{}
	}
	mut g := []string{}
	for i, r in m.routines {
		g << '\t\tC.iocb_get(${routine_cell(m, i, true)}, &g_diag.server.routines[${i}].res) // routine "${r.name}": its FB\'s latest report, before the deadline is judged'
	}
	return g
}

// routine_target_pass: the routines' share of the comm-thread pass, in `.reports` after the faults'
// — the request the server wrote published (a stop its housekeeping asked included)
fn routine_target_pass(m Model) []string {
	if !routine_target_on(m) {
		return []string{}
	}
	mut g := []string{}
	for i, r in m.routines {
		g << '\t\tC.iocb_pub(${routine_cell(m, i, false)}, &g_diag.server.routines[${i}].req) // routine "${r.name}": the request the server wrote'
	}
	return g
}

// routine_target_boot: each routine cell's byte-IOC arena, sized to its struct, before any thread runs
fn routine_target_boot(m Model) []string {
	if !routine_target_on(m) {
		return []string{}
	}
	mut g := []string{}
	for i, r in m.routines {
		g << '\tC.iocb_cfg(${routine_cell(m, i, false)}, u16(sizeof(uds.RoutineRequest))) // routine "${r.name}": request'
		g << '\tC.iocb_cfg(${routine_cell(m, i, true)}, u16(sizeof(uds.RoutineResult))) // routine "${r.name}": result'
	}
	return g
}

// routine_bridge_results: the host bridge's pass, BEFORE connection `conn`'s housekeeping — each
// FB's latest report read into its server, so a result the FB published before a routine's
// deadline is in its cell when the server's tick judges that deadline (comm/uds pending.v)
fn routine_bridge_results(m Model, conn string) []string {
	mut g := []string{}
	for i, r in m.routines {
		f := snake(r.name)
		cell := '${conn}.server.routines[${i}]'
		g << '\tosal.${acquire_fn('triple')}(routine_res_${f}_ch, &${cell}.res, u8(sizeof(${cell}.res))) // routine "${r.name}": its FB\'s latest report, before the deadline is judged'
	}
	return g
}

// routine_bridge_lines: the host bridge's share of its pass, right after the faults' — the request
// connection `conn`'s server wrote published (a stop its housekeeping asked included)
fn routine_bridge_lines(m Model, conn string) []string {
	mut g := []string{}
	for i, r in m.routines {
		f := snake(r.name)
		cell := '${conn}.server.routines[${i}]'
		g << '\tosal.${publish_fn('triple')}(routine_req_${f}_ch, &${cell}.req, u8(sizeof(${cell}.req))) // routine "${r.name}": the request the server wrote'
	}
	return g
}

// owed_target_on: the server of a ThreadX image can owe an answer (comm/uds pending.v) — a routine
// runs in its FB, or a 0x29 proof is verified a slice per pass (comm/uds auth.v)
fn owed_target_on(m Model) bool {
	return routine_target_on(m) || (m.target.threadx && auth_on(m))
}

// routine_push_globals: a [doip] node's buffer for the responses an owed answer pushes (bss: its
// address reaches C)
fn routine_push_globals(m Model) []string {
	if !m.doip.on || !owed_target_on(m) {
		return []string{}
	}
	return ['\tg_diag_push [doipnet.push_max]u8 // an owed answer\'s responses pushed over DoIP (comm/diag push_step)']
}

// routine_push_lines: a [doip] node's comm thread, after the mailbox: an answer owed to the DoIP
// tester (a routine's or a 0x29 proof's: a responsePending, the final answer) pushed once the
// response before it was acknowledged
fn routine_push_lines(m Model) []string {
	if !m.doip.on || !owed_target_on(m) {
		return []string{}
	}
	return [
		'\t\tif doipnet.take_push_sent() {',
		'\t\t\tg_diag.push_sent() // the response pushed last was acknowledged',
		'\t\t}',
		'\t\tpush_n := g_diag.push_step(&g_diag_push[0], doipnet.push_max) // the next response of an answer owed over DoIP',
		'\t\tif push_n > 0 {',
		'\t\t\tg_diag.pushed(doipnet.push_resp(&g_diag_push[0], push_n))',
		'\t\t}',
	]
}
