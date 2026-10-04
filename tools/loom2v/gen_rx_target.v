module main

import toml
import tools.ecumodel

// The ThreadX comm thread's receive path (R5, docs/diagnostics.md §3.2): the host bridge's
// templates (gen_rx.v) over the target's seams. A received frame that needs the COM receive rule —
// a deadline, E2E or SecOC, a signal with a status or lost count, or a layout the lean whole-frame
// copy cannot hand over — is decoded by the DBC codec, judged by com.RxMonitor, and its signals
// cross to the FBs as whole structs through the byte IOC (boards/common/iocb.c), status included.
// Every other received frame keeps the lean path (one u32 through the scalar IOC pool).

// fb_read_counts: how many FB handlers read each signal.
fn fb_read_counts(doc toml.Doc) map[string]int {
	mut n := map[string]int{}
	for fb in ecumodel.toml_arr(doc, 'fb') {
		for h in (fb.as_map()['handler'] or { toml.Any([]toml.Any{}) }).array() {
			for r in (h.as_map()['reads'] or { toml.Any([]toml.Any{}) }).array() {
				n[r.string()]++
			}
		}
	}
	return n
}

// fb_reads_of: the signals each FB's handlers read.
fn fb_reads_of(doc toml.Doc) map[string][]string {
	mut out := map[string][]string{}
	for fb in ecumodel.toml_arr(doc, 'fb') {
		fm := fb.as_map()
		name := (fm['name'] or { toml.Any('') }).string()
		for h in (fm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			for r in (h.as_map()['reads'] or { toml.Any([]toml.Any{}) }).array() {
				if r.string() !in (out[name] or { []string{} }) {
					out[name] << r.string()
				}
			}
		}
	}
	return out
}

// rx_target_sigs: the signals a ThreadX comm thread receives on CAN for somebody — an FB reads
// it, or a signal-status fault watches it — by DBC message, in declaration order.
fn rx_target_sigs(m Model) map[string][]string {
	mut out := map[string][]string{}
	if !m.target.threadx {
		return out
	}
	sources := fault_sources(m)
	for sname in m.sig_names {
		si := m.sig_of[sname] or { continue }
		if !si.external || !si.rx || (m.eth != '' && si.bus == m.eth) {
			continue
		}
		if (m.fb_reads[sname] or { 0 }) == 0 && sname !in sources {
			continue
		}
		out[si.dbc_msg] << sname
	}
	return out
}

// rx_checked_msgs: the received frames the comm thread runs through the COM receive rule, sorted.
fn rx_checked_msgs(m Model) []string {
	mut out := []string{}
	for msg, list in rx_target_sigs(m) {
		bus := (m.sig_of[list[0]] or { SigInfo{} }).bus
		mut checked := rx_monitored(m, msg, bus) || list.len > 1
		for sname in list {
			si := m.sig_of[sname] or { continue }
			if si.has_status || si.lost_type != '' || !si.dbc_trivial || sname in fault_sources(m) {
				checked = true
			}
		}
		if checked {
			out << msg
		}
	}
	out.sort()
	return out
}

// rx_iocb_idx: each signal crossing threads through the byte IOC — the eth signals first, at the
// indexes eth_iocb_idx gives them, then the checked CAN signals an FB reads, by name. The one
// numbering the FB glue, the comm and eth threads and boot share.
fn rx_iocb_idx(m Model) map[string]int {
	mut idx := eth_iocb_idx(m)
	mut names := []string{}
	sigs := rx_target_sigs(m)
	for msg in rx_checked_msgs(m) {
		for sname in sigs[msg] or { []string{} } {
			if (m.fb_reads[sname] or { 0 }) > 0 && sname !in idx {
				names << sname
			}
		}
	}
	names.sort()
	base := idx.len
	for i, n in names {
		idx[n] = base + i
	}
	return idx
}

// CommStep is one step of the ThreadX comm thread's pass. comm_pass_order is the ONE order the
// generator emits them in (emit_run_target), with the reception gate re-sampled at every point that
// can change it, so no frame is judged by a stale gate:
//   housekeep  the connection's timers (S3, a pending reset)
//   open       the pass clock; the gate's first sampling; signal-status faults' level steps
//   reports    the FBs' fault reports consumed
//   remote     a DoIP request served — then the gate re-sampled (a 0x28 over IP)
//   drain      the FIFO, frame by frame: a CAN request served re-samples the gate (a 0x28 on CAN);
//              an NM frame that wakes the network re-samples it and starts the operation cycle
//              (comm_nm_transition) before the next frame is judged
//   tick       NM's state machine
//   cycle      the operation cycle follows the tick — before settle consumes a deadline occurrence
//   settle     the gate's last sampling, the restart, the deadlines
//   persist    the snapshots after the pass's LAST consume, then the journal write — a DTC stored
//              is never one whose snapshot is still due
// (the producers — NM's gate, the diagnostic answer, telemetry, COM tx — follow, unchanged)
enum CommStep {
	housekeep
	open
	reports
	remote
	drain
	tick
	cycle
	settle
	persist
}

const comm_pass_order = [CommStep.housekeep, .open, .reports, .remote, .drain, .tick, .cycle, .settle,
	.persist]

// comm_nm_watched: an NM transition inside the drain matters to the pass — the gate waits on NM's
// sleep, or NM moves the operation cycle.
fn comm_nm_watched(m Model) bool {
	return m.nm.on && (rx_target_owner(m).awake != '' || (fault_target_on(m) && m.fault_cycle == ''))
}

// comm_nm_seen: NM's awake state as the drain last acted on it.
fn comm_nm_seen(m Model) []string {
	if !comm_nm_watched(m) {
		return []string{}
	}
	return ['\t\tmut nm_seen := g_nm.awake() // NM as the drain last acted on it']
}

// comm_nm_transition: after the NM arm, inside the drain — an NM frame that woke the network takes
// effect before the next frame: the gate re-sampled (the deadlines and loss suppression see the
// wake) and the operation cycle started, so an occurrence after the wake is recorded in it.
fn comm_nm_transition(m Model) []string {
	if !comm_nm_watched(m) {
		return []string{}
	}
	mut out := [
		'\t\t\tif g_nm.awake() != nm_seen { // an NM frame moved NM: what follows sees it',
		'\t\t\t\tnm_seen = g_nm.awake()',
	]
	out << rx_target_resample(m, '\t\t\t\t')
	out << fault_target_cycle(m, 'C.board_now_us()', '\t\t\t\t')
	out << '\t\t\t}'
	return out
}

// rx_target_bus: the bus the comm thread receives on (its telemetry bus).
fn rx_target_bus(m Model) string {
	return m.telem.bus
}

// rx_target_on: the comm thread keeps receive state — checked frames, or a reception gate for the
// lean ones because a diagnostic server can switch reception off (0x28).
fn rx_target_on(m Model) bool {
	return m.target.threadx && (rx_checked_msgs(m).len > 0 || m.isotp_conns.len > 0)
}

// rx_target_owner: the comm thread as an owner of the receive path — the fault memory g_fmem, the
// server's 0x28 gate, NM's sleep, the byte IOC.
fn rx_target_owner(m Model) RxOwner {
	idx := rx_iocb_idx(m)
	return RxOwner{
		fmem: 'g_fmem'
		rx_on: if m.isotp_conns.len > 0 { 'g_diag.server.rx_enabled()' } else { '' }
		awake: if m.nm.on && rx_checked_msgs(m).len > 0 { 'g_nm.awake()' } else { '' }
		faults: m.faults.any(it.signal != '')
		publish: fn [idx] (si SigInfo, fld string) string {
			if i := idx[si.name] {
				return 'C.iocb_pub(${i}, &${fld}) // to the FBs, status and all'
			}return ''
		}
	}
}

// rx_target_struct: the comm thread's receive state, a type of its own so the shared templates'
// `st.` reaches it (the thread points `st` at its bss instance).
fn rx_target_struct(m Model) []string {
	if !rx_target_on(m) {
		return []string{}
	}
	mut out := ['',
		"// the comm thread's receive state (gen_rx.v templates): monitors, the reception gate,",
		"// the signal-status faults' debouncers", 'struct CommRx_state {', 'mut:']
	out << rx_state_fields(m, rx_checked_msgs(m), rx_target_bus(m), rx_target_owner(m))
	out << signal_fault_fields(m)
	out << '}'
	return out
}

// rx_target_global: its bss instance.
fn rx_target_global(m Model) []string {
	if !rx_target_on(m) {
		return []string{}
	}
	return ["\tg_crx CommRx_state // the comm thread's receive state (bss)"]
}

// rx_target_init: at the comm thread's start, after the fault memory is configured — the
// deadlines armed from now, the debouncers set.
fn rx_target_init(m Model) []string {
	if !rx_target_on(m) {
		return []string{}
	}
	mut out := ['\tmut st := &g_crx']
	out << rx_state_init(m, rx_checked_msgs(m), rx_target_bus(m), 'C.board_now_us()', '\t')
	out << signal_fault_init(m, '\t')
	return out
}

// rx_target_top: the top of a pass, after the connection's housekeeping and before the fault
// memory consumes the FBs' reports — the clock, the gate's first sampling, and the signal-status
// faults' level steps (the host bridge's order).
fn rx_target_top(m Model) []string {
	if !rx_target_on(m) {
		return []string{}
	}
	owner := rx_target_owner(m)
	mut out := []string{}
	if rx_checked_msgs(m).any(rx_monitored(m, it, rx_target_bus(m))) || owner.faults {
		out << "\t\tnow := C.board_now_us() // the receive rule's clock for this pass"
	}
	out << rx_gate_lines(m, rx_checked_msgs(m), rx_target_bus(m), owner, '\t\t')
	if owner.faults {
		out << signal_fault_step_lines(m, owner, '\t\t')
	}
	return out
}

// rx_target_arms: the checked frames' branches of the drain.
fn rx_target_arms(m Model) []string {
	mut out := []string{}
	if !rx_target_on(m) {
		return out
	}
	owner := rx_target_owner(m)
	sigs := rx_target_sigs(m)
	for msg in rx_checked_msgs(m) {
		list := sigs[msg] or { continue }
		ext := (m.sig_of[list[0]] or { SigInfo{} }).dbc_ext
		arm := rx_frame_arm(m, msg, list, ext, rx_target_bus(m), owner, '\t\t\t')
		// the frame counter the lean arms keep, for an SWD reader
		out << arm[0]
		out << '\t\t\t\tg_rx_count++'
		out << arm[1..]
	}
	return out
}

// rx_target_resample: the gate re-sampled where a request was served inside the drain — a 0x28
// answered on arrival gates the frames queued behind it.
fn rx_target_resample(m Model, ind string) []string {
	if !rx_target_on(m) {
		return []string{}
	}
	return rx_gate_lines(m, rx_checked_msgs(m), rx_target_bus(m), rx_target_owner(m), ind)
}

// rx_target_settle: after the drain, NM's tick and the cycle it moves — the gate's last sampling,
// the restart and the deadlines (their occurrences are captured at .persist).
fn rx_target_settle(m Model) []string {
	if !rx_target_on(m) {
		return []string{}
	}
	mut out := []string{}
	owner := rx_target_owner(m)
	sigs := rx_target_sigs(m)
	mut list_of := map[string][]string{}
	for msg in rx_checked_msgs(m) {
		list_of[msg] = sigs[msg] or { []string{} }
	}
	out << rx_settle_lines(m, rx_checked_msgs(m), list_of, rx_target_bus(m), owner, '\t\t')
	return out
}

// rx_target_boot: the byte-IOC arena of each checked signal an FB reads, sized to its struct.
fn rx_target_boot(m Model) []string {
	mut out := []string{}
	eth := eth_iocb_idx(m)
	idx := rx_iocb_idx(m)
	mut names := idx.keys().filter(it !in eth)
	names.sort()
	for n in names {
		out << '\tmut cfg_${snake(n)} := sig.${n}{}'
		out << '\tC.iocb_cfg(${idx[n]}, u16(sizeof(cfg_${snake(n)}))) // ${n}: received, checked'
	}
	return out
}

// ioc_max: boards/common/ioc.h IOC_MAX, the most one IOC cell carries (pinned by rx_target_test.v)
const ioc_max = 64

// sig_struct_size: the byte size of a signal's generated struct (sig.<Name>), laid out as C lays
// out its fields in declaration order — each aligned to its own size, the whole to the largest.
fn sig_struct_size(si SigInfo) int {
	mut off := 0
	mut align := 1
	for f in si.fields {
		n := match f.typ {
			'bool', 'u8', 'i8', 'RxStatus' { 1 }
			'u16', 'i16' { 2 }
			'u32', 'i32', 'f32' { 4 }
			else { 8 }
		}
		// u64, i64, f64
		off = (off + n - 1) / n * n + n
		if n > align {
			align = n
		}
	}
	return (off + align - 1) / align * align
}

// diag_tx_gate: the comm thread's application producers wait on 0x28's transmit gate too.
fn diag_tx_gate(m Model) string {
	if m.target.threadx && m.isotp_conns.len > 0 {
		return 'g_diag.server.tx_enabled() && '
	}
	return ''
}

// validate_rx_target: what a checked frame on the comm thread needs. Each byte-IOC cell has ONE
// reader slot, so a checked signal is read from one FB thread; the cells come from a pool of
// iocb_pool_n beside the eth signals and the fault cells.
fn validate_rx_target(m Model) {
	idx := rx_iocb_idx(m)
	eth := eth_iocb_idx(m)
	for sname, _ in idx {
		// a cell carries one whole signal struct, at most IOC_MAX bytes: iocb_cfg parks the image at
		// boot on a larger one, so it is refused here
		size := sig_struct_size(m.sig_of[sname] or { SigInfo{} })
		if size > ioc_max {
			panic('loom2v: [target] kind="threadx": signal "${sname}" is ${size} bytes as a struct, but a byte-IOC cell carries at most ${ioc_max} (boards/common/ioc.h IOC_MAX) — split it')
		}
		if sname in eth {
			continue
		}
		mut threads := []string{}
		for fb, thr in m.part.fb_thread {
			if sname in (m.fb_reads_by[fb] or { []string{} }) && thr !in threads {
				threads << thr
			}
		}
		if threads.len > 1 {
			threads.sort()
			panic('loom2v: [target] kind="threadx": received signal "${sname}" is read on ${threads.len} threads (${threads.join(', ')}) — its byte-IOC cell has one reader slot; read it on one thread')
		}
	}
	if why := iocb_overflow(m) {
		panic('loom2v: [target] kind="threadx": ${why}')
	}
}

// iocb_overflow: why the image's byte-IOC cells do not fit the pool — the signal cells (eth signals
// and checked received ones, rx_iocb_idx) and two per fault-owning FB — or none. The one statement
// of the bound, asked by the fault and the receive validations alike.
fn iocb_overflow(m Model) ?string {
	sigs := rx_iocb_idx(m).len
	faults := 2 * fault_fbs(m).len
	if sigs + faults <= iocb_pool_n {
		return none
	}
	return '${sigs} signal cell(s) (eth signals and checked received ones) and ${faults} fault cell(s) exceed the byte-IOC pool of ${iocb_pool_n} (boards/common/iocb.c IOCB_POOL_N)'
}
