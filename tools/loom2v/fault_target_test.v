module main

// @verifies REQ-DIAG-012
import os
import time

// Faults on a ThreadX target (docs/diagnostics.md R6): the fault memory on the comm thread, each
// fault-owning FB's report and control cells on the byte IOC, the operation cycle from NM (D3) or
// the power cycle — and what stays refused. Runs the real generator on examples/h735_threadx with
// its FBs on one thread and a connection and faults appended (a refusal is a panic, which cannot be
// caught in-process).

const ft_conn = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF
'

const ft_fault = '
[[fault]]
name     = "LoadImplausible"
dtc      = 0xC40100
from     = "LoadSlow.on_100ms"
debounce = { kind = "counter", fail = 3, pass = 3 }

[nvm]
min_write_ms = 1000
'

const ft_bin = os.join_path(os.temp_dir(), 'loom2v_fault_target_${os.getpid()}_${time.now().unix_nano()}')

// the generator is built once per run, from the source under test, and removed after it
fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${ft_bin} ${os.join_path(@VMODROOT, 'tools',
		'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(ft_bin) or {}
}

fn ft_loom2v() string {
	return ft_bin
}

// one_thread: h735_threadx with every FB on its first thread — faults in a multi-thread partition
// are not generated yet (the refusal is the host's too).
fn one_thread(src string) string {
	mut s := src
	for t in ['load_mid', 'ctrl_slow'] {
		at := s.index('  [[partition.thread]]\n  name     = "${t}"') or { panic('no thread ${t}') }
		end := s.index_after('\n\n', at) or { panic('no end of thread ${t}') }
		s = s[..at] + s[end + 2..]
		s = s.replace('thread    = "${t}"', 'thread    = "load_fast"')
	}
	return s
}

// ft_generate runs loom2v on the one-thread h735_threadx with `edit` applied and `extra` appended;
// returns the exit code, the output, the glue and gen/loom_build.mk.
fn ft_generate(name string, edit fn (string) string, extra string) (int, string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'fault_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	ex := os.join_path(@VMODROOT, 'examples', 'h735_threadx')
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	os.write_file(ecu, edit(one_thread(src)) + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(ex, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${ft_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }, os.read_file(os.join_path(tmp,
		'loom_build.mk')) or { '' }
}

fn same(src string) string {
	return src
}

// in_order asserts every step appears in `glue`, each after the one before it
fn in_order(glue string, steps []string) {
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}

fn test_the_comm_thread_owns_the_fault_memory_and_nm_moves_its_cycle() {
	code, out, glue, mk := ft_generate('nm', same, ft_conn + ft_fault)
	assert code == 0, out
	// the FB side: debounce after the handler, the cells on the byte IOC (no osal on a target)
	in_order(glue, [
		'fdeb_load_slow [1]fault.Debounce',
		'fctl_load_slow fault.Control',
		'frep_load_slow fault.Reports',
		'st.load_slow.on_100ms(inp, mut outp)',
		'fault_now := C.board_now_us()',
		'C.iocb_get(1, &st.fctl_load_slow)',
		'st.fdeb_load_slow[0].apply(st.fctl_load_slow.gen[0], st.fctl_load_slow.held[0])',
		'st.fdeb_load_slow[0].step(outp.fault.load_implausible, fault_now, true)',
		'C.iocb_pub(0, &st.frep_load_slow)',
	])
	assert !glue.contains('fault_rep_load_slow_ch'), 'a target FB published through osal'
	// the debouncer is configured when the FB thread starts
	in_order(glue, ['pub fn run() {', 'mut st := Partition_app_state{}', 'st.fdeb_load_slow[0] = fault.Debounce{',
		'fail_thr: 3', 'for {'])
	// the comm thread: the memory in bss, configured after the connection, consumed at the pass
	// top (before the drain serves a request), its cycle moved by NM after the NM tick
	in_order(glue, [
		'g_fmem fault.Memory',
		'g_fcycle_on bool',
		'g_frep_load_slow fault.Reports',
		'g_fctl_load_slow fault.Control',
		'fn comm_thread_entry(',
		'g_diag.init(',
		'g_fmem.slots[0].dtc = u32(0xc40100) // LoadImplausible',
		'g_fmem.slots[0].confirm = u8(1)',
		'g_fmem.n = 1',
		'g_fmem.init()',
		'g_diag.server.faults = g_fmem.uds_ops()',
		// NM may start awake: the cycle begins before the loop's first consume (codex on #350 r3)
		'g_fcycle_on = g_nm.awake()',
		'g_fmem.cycle_start()',
		'for {',
		'g_diag.housekeep(',
		'C.iocb_get(0, &g_frep_load_slow)',
		'g_fmem.consume(0, g_frep_load_slow.r[0])',
		'g_fctl_load_slow.gen[0] = g_fmem.control_gen(0)',
		'g_fctl_load_slow.held[0] = g_fmem.control_held(0)', // a held generation, beside it (#364)
		'C.iocb_pub(1, &g_fctl_load_slow)',
		'for ch.recv(mut rx) {',
		'g_diag.serve()',
		'g_nm.produce(t1, mut nm_txf)',
		'if g_nm.awake() != g_fcycle_on {',
		'g_fmem.cycle_start()',
		// the falling edge consumes what the FBs reported since the pass top before ending it
		'} else {',
		'C.iocb_get(0, &g_frep_load_slow)',
		'g_fmem.consume(0, g_frep_load_slow.r[0])',
		'g_fmem.cycle_end()',
		'nm_up := g_nm.awake()',
	])
	assert !glue.contains('g_fmem.cycle_start() // [fault_memory] cycle = "power"')
	// both cells' arenas exist before any thread runs
	in_order(glue, ['fn tx_application_define(', 'C.iocb_cfg(0, u16(sizeof(fcfg_rep)))',
		'C.iocb_cfg(1, u16(sizeof(fcfg_ctl)))', 'C._tx_initialize_kernel_enter()'])
	assert glue.contains('fn C.iocb_get(int, voidptr)')
	// the image links the byte IOC
	assert mk.contains('LOOM_FAULT_SRCS = $(REPO)/boards/common/iocb.c'), mk
}

// a server table may list what the fault memory serves on the target — it performs it now
fn test_the_target_serves_0x14_0x19_0x85_from_its_table() {
	table := '
[uds.services]
"0x10" = {}
"0x14" = {}
"0x19" = {}
"0x22" = {}
"0x3E" = {}
"0x85" = {}
'
	code, out, glue, _ := ft_generate('table', same, ft_conn + ft_fault + table)
	assert code == 0, out
	assert glue.contains('g_diag.server.services[1] = uds.Service{sid: 0x14}')
	assert glue.contains('g_diag.server.services[2] = uds.Service{sid: 0x19}')
	assert glue.contains('g_diag.server.services[5] = uds.Service{sid: 0x85}')
	// without a fault memory the same table is refused, as on the host
	c2, o2, _, _ := ft_generate('table_nofault', same, ft_conn + table)
	assert c2 != 0
	assert o2.contains('0x14: this build cannot perform it — the node has no fault memory'), o2
}

// a node with no NM states its cycle: the power cycle begins with the comm thread
fn test_the_power_cycle_begins_with_the_comm_thread() {
	no_nm := fn (src string) string {
		at := src.index('[nm]') or { panic('no [nm]') }
		end := src.index_after('\n\n', at) or { panic('no end of [nm]') }
		return src[..at] + src[end + 2..]
	}
	code, out, glue, _ := ft_generate('power', no_nm, ft_conn + ft_fault +
		'\n[fault_memory]\ncycle = "power"\n')
	assert code == 0, out
	in_order(glue, ['g_fmem.init()', 'g_diag.server.faults = g_fmem.uds_ops()',
		'g_fmem.cycle_start() // [fault_memory] cycle = "power"', 'for {'])
	assert !glue.contains('g_fcycle_on')
	assert !glue.contains('g_fmem.cycle_end()')
	// and with neither NM nor a declared cycle, nothing would ever start one
	c2, o2, _, _ := ft_generate('nocycle', no_nm, ft_conn + ft_fault)
	assert c2 != 0
	assert o2.contains('needs an operation cycle: [nm]'), o2
}

// The fault memory on the target is persisted (R6b): wired to the journal and restored from it
// before the power cycle begins, written every pass after the cycle's step, flushed with the
// persisted signals at every quiet point (the ECUReset included, after the latest reports and
// their snapshots), its blocks in the prune keep-set, a node without NM erasing at boot — and the
// journal's storage and flash driver linked by the generator, never named in a Makefile.
fn test_the_fault_memory_is_persisted_in_the_journal() {
	no_nm := fn (src string) string {
		at := src.index('[nm]') or { panic('no [nm]') }
		end := src.index_after('\n\n', at) or { panic('no end of [nm]') }
		return src[..at] + src[end + 2..]
	}
	snap := ft_conn + '[[did]]\nid    = 0xF190\nascii = "BLOBLY"\n' + ft_fault.replace('fail = 3, pass = 3 }',
		'fail = 3, pass = 3 }\nfreeze   = [0xF190]\npriority = 7') + '\n[fault_memory]\ncycle = "power"\n'
	code, out, glue, mk := ft_generate('persist', no_nm, snap)
	assert code == 0, out
	in_order(glue, ['fn comm_thread_entry', 'g_fmem.slots[0].priority = u8(7)', 'g_fmem.slots[0].freeze[0] = u16(0xf190)',
		'g_fmem.slots[0].freeze_len[0] = u8(6)', 'g_fmem.slots[0].nfreeze = 1', 'g_fmem.slots[0].snap_id = u16(0x',
		'g_fmem.cap = 1', 'g_fmem.init()', 'g_fmem.store = fault.Store{', 'g_fmem.restore()',
		'g_fmem.cycle_start() // [fault_memory] cycle = "power"', 'for {',
		'g_fmem.consume(0, g_frep_load_slow.r[0])', 'if g_fmem.capture_due() {', 'g_diag.refresh_now()',
		'g_fmem.capture(&g_diag.server)', 'g_fmem.persist(t1, false)',
		'if g_diag.reset_due() != 0 {', 'g_fmem.consume(0, g_frep_load_slow.r[0])',
		'if !g_fmem.persist(t1, true) {', 'C.diag_sys_reset()', 'fn fmem_put(ctx voidptr, id u16, data &u8, len u16) bool {',
		'return g_nvm.put(id, data, len)', 'pub fn boot() {', 'if g_nvm.mounted {',
		'keep := [', '/* the fault memory status */', 'g_nvm.prune(&keep[0], 2)',
		'g_nvm.erase_pending() // the boot quiet point (no NM)'])
	assert mk.contains(r'$(REPO)/boards/common/nvm_map.c $(BOARD_FLASH)'), mk
	// with NM: no erase at boot (the sleep edges are the quiet points), and a write made in bus
	// sleep re-lays the clean marker through the whole choreography
	c2, o2, g2, _ := ft_generate('persist_nm', same, ft_conn + ft_fault)
	assert c2 == 0, o2
	assert !g2.contains('g_nvm.erase_pending() // the boot quiet point')
	in_order(g2, ['g_fmem.persist(t1, false)', 'if g_fmem.wrote > 0 && g_nm.state() == .bus_sleep {',
		'if !g_fmem.persist(t1, true) {', 'g_nvm.mark_clean()'])
	// and no persistence without the storage declared
	c3, o3, _, _ := ft_generate('nonvm', same, ft_conn + ft_fault.all_before('[nvm]'))
	assert c3 != 0
	assert o3.contains('[[fault]] on the target needs [nvm]'), o3
}

// A snapshot names this node's DIDs, at most max_freeze of them, each readable wherever 0x19 is —
// never a side door around a DID's gate (docs/diagnostics.md §7) — and the entries are bounded.
fn test_snapshot_declarations_are_checked() {
	did := '[[did]]\nid    = 0xF190\nascii = "BLOBLY"\n[[did]]\nid    = 0xF191\nascii = "X"\nread  = { session = ["extended"] }\n'
	cases := {
		'unknown':  ['freeze = [0xF1A9]', 'is not a [[did]] of this node']
		'twice':    ['freeze = [0xF190, 0xF190]', 'names DID 0xf190 twice']
		'gated':    ['freeze = [0xF191]', 'is not readable in every session 0x19 is served in']
		'many':     ['freeze = [0xF190, 0xF191, 1, 2, 3]', 'a snapshot holds at most 4']
		'priority': ['priority = 0', 'priority 0 must be 1']
	}
	for name, c in cases {
		code, out, _, _ := ft_generate('snap_${name}', same, ft_conn + did + ft_fault.replace('fail = 3, pass = 3 }',
			'fail = 3, pass = 3 }\n' + c[0]))
		assert code != 0, name
		assert out.contains(c[1]), '${name}: ${out}'
	}
	for entries, msg in {
		'0': 'entries = 0 must be 1 .. 8'
		'9': 'entries = 9 must be 1 .. 8'
	} {
		code, out, _, _ := ft_generate('entries_${entries}', same, ft_conn + did + ft_fault.replace('fail = 3, pass = 3 }',
			'fail = 3, pass = 3 }\nfreeze = [0xF190]') + '\n[fault_memory]\nentries = ${entries}\n')
		assert code != 0 && out.contains(msg), out
	}
	code, out, _, _ := ft_generate('entries_nosnap', same, ft_conn + ft_fault + '\n[fault_memory]\nentries = 1\n')
	assert code != 0 && out.contains('no [[fault]] declares a snapshot'), out
	// a journal too small for the fault memory and its rewrite headroom
	wide := '[[did]]\nid    = 0xF192\nascii = "${'W'.repeat(32)}"\n'
	c2, o2, _, _ := ft_generate('tiny', same, ft_conn + wide + ft_fault.replace('fail = 3, pass = 3 }',
		'fail = 3, pass = 3 }\nfreeze = [0xF192]') + 'sector_records = 8\n')
	assert c2 != 0 && o2.contains('records of sector headroom'), o2
}

fn test_what_the_target_does_not_generate_yet_is_refused() {
	// a cycle signal: the comm thread's lean decode keeps no bool to watch
	code, out, _, _ := ft_generate('cycsig', same, ft_conn + ft_fault +
		'\n[fault_memory]\ncycle = "Command.code"\n')
	assert code != 0
	assert out.contains('a cycle signal on the target is not generated yet'), out
	// a signal-status fault: the target's comm thread runs no rx status yet (R5)
	sigf := '
[[fault]]
name   = "CommandTimeout"
dtc    = 0xC10000
signal = "Command"
on     = "timeout"
'
	c2, o2, _, _ := ft_generate('sigfault', same, ft_conn + sigf)
	assert c2 != 0
	assert o2.contains('a signal-status fault on the target needs'), o2
	// faults in a multi-thread partition (the original layout), as on the host
	c3, o3, _, _ := ft_generate('multi', fn (src string) string {
		return os.read_file(os.join_path(@VMODROOT, 'examples', 'h735_threadx', 'ecu.toml')) or {
			panic(err)
		}
	}, ft_conn + ft_fault)
	assert c3 != 0
	assert o3.contains('in a multi-thread partition — not generated yet'), o3
}

// the cells: two per fault-owning FB, after the eth signals' channels, in first-declaration order
fn test_fault_cells_follow_the_eth_channels() {
	mut m := Model{}
	m.target.threadx = true
	m.faults = [
		FaultCfg{
			name: 'A'
			fb:   'Second'
		},
		FaultCfg{
			name: 'B'
			fb:   'First'
		},
		FaultCfg{
			name: 'C'
			fb:   'Second'
		},
	]
	assert fault_cell(m, 'Second', false) == 0
	assert fault_cell(m, 'Second', true) == 1
	assert fault_cell(m, 'First', false) == 2
	assert fault_cell(m, 'First', true) == 3
}

// both owners configure and consume the fault memory through the same lines — only the names of
// the memory and the cells differ — so the target answers 0x19 from the state the host would
fn test_the_target_and_the_host_feed_the_memory_alike() {
	mut m := Model{}
	m.faults = [
		FaultCfg{
			name:    'A'
			dtc:     0x123456
			fb:      'Mon'
			confirm: 2
			aging:   3
		},
		FaultCfg{
			name:    'B'
			dtc:     0x654321
			fb:      'Mon'
			confirm: 1
		},
	]
	host := fault_slot_lines(m, 'st.fmem', '\t').join('\n') + '\n' +
		fault_consume_lines(m, 'Mon', 'st.fmem', 'st.frep_mon', 'st.fctl_mon', '\t').join('\n')
	m.target.threadx = true
	target := fault_slot_lines(m, 'g_fmem', '\t').join('\n') + '\n' +
		fault_consume_lines(m, 'Mon', 'g_fmem', 'g_frep_mon', 'g_fctl_mon', '\t').join('\n')
	assert target == host.replace('st.fmem', 'g_fmem').replace('st.frep_mon', 'g_frep_mon').replace('st.fctl_mon',
		'g_fctl_mon')
	assert host.contains('st.fmem.consume(1, st.frep_mon.r[1])')
	assert host.contains('st.fmem.slots[0].aging = u8(3)')
}

// the power cycle is the host bridge's to choose too: begun at bridge start, moved by no frame
fn test_the_host_bridge_takes_the_power_cycle_too() {
	tmp := os.join_path(os.temp_dir(), 'fault_target_host_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	ex := os.join_path(@VMODROOT, 'examples', 'overspeed')
	os.mkdir_all(tmp) or { panic(err) }
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	assert src.contains('cycle = "IgnitionOn.on"')
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, src.replace('cycle = "IgnitionOn.on"', 'cycle = "power"')) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(ex, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${ft_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	assert r.exit_code == 0, r.output
	g := os.read_file(glue) or { panic(err) }
	in_order(g, ['st.fmem.init()', 'st.conn_diag.server.faults = st.fmem.uds_ops()',
		'st.fmem.cycle_start() // [fault_memory] cycle = "power"'])
	assert g.count('st.fmem.cycle_start()') == 1, 'a frame still moves the cycle'
	assert !g.contains('st.fmem.cycle_end()')
}

// the pool bound the validator applies is the one the board glue allocates
fn test_the_byte_ioc_pool_bound_is_the_glues() {
	c := os.read_file(os.join_path(@VMODROOT, 'boards', 'common', 'iocb.c')) or { panic(err) }
	assert c.contains('#define IOCB_POOL_N     ${iocb_pool_n}\n'), 'iocb_pool_n (${iocb_pool_n}) is not boards/common/iocb.c IOCB_POOL_N'
}
