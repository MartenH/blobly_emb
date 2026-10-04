module main

// @verifies REQ-DIAG-017
import os
import time

// Parameters on a ThreadX target (docs/diagnostics.md §3.4, R7): the table restored before the
// kernel and published into each reading FB's IOC cell, bound to the server on the comm thread, its
// journal blocks in the prune keep-set — and what generation refuses. Runs the real generator on
// testdata/threadx_node with its FBs on one thread and a connection, [nvm] and parameters appended
// (a refusal is a panic, which cannot be caught in-process).

const fixture_dir = os.join_path(@DIR, 'testdata', 'threadx_node')

const pt_conn = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[nvm]
min_write_ms = 1000
'

const pt_param = '
[[param]]
name    = "LoadCap"
fields  = { iters = "u16", strict = "bool" }
default = { iters = 500, strict = false }
range   = { iters = { min = 10, max = 1000 } }

[[param]]
name    = "Trim"
fields  = { x = "i8" }
default = { x = -3 }
apply   = "reset"

[[did]]
id    = 0x0110
param = "LoadCap"
write = { session = ["extended"], security = 1 }

[[did]]
id    = 0x0111
param = "Trim"
write = { session = ["extended"], security = 1 }

[[did]]
id           = 0x0112
param_status = true
'

const pt_bin = os.join_path(os.temp_dir(), 'loom2v_param_target_${os.getpid()}_${time.now().unix_nano()}')

fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${pt_bin} ${os.join_path(@VMODROOT, 'tools',
		'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(pt_bin) or {}
}

// one_thread: the fixture with every FB on its first thread
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

// reads_params: LoadSlow reads both parameters beside LoadCmd
fn reads_params(src string) string {
	return src.replace('  reads     = ["LoadCmd"]\n  writes    = ["Workload"]',
		'  reads     = ["LoadCmd", "LoadCap", "Trim"]\n  writes    = ["Workload"]')
}

struct PtOut {
	code     int
	out      string
	glue     string
	ports    string
	sig      string
	manifest string
}

// pt_generate runs loom2v on the one-thread fixture with `edit` applied and `extra` appended.
fn pt_generate(name string, edit fn (string) string, extra string) PtOut {
	tmp := os.join_path(os.temp_dir(), 'param_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	src := os.read_file(os.join_path(fixture_dir, 'ecu.toml')) or { panic(err) }
	os.write_file(ecu, edit(one_thread(src)) + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(fixture_dir, 'bus.dbc'), dbc) or { panic(err) }
	r := os.execute('${pt_bin} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${os.join_path(tmp, 'gen.v')} ${os.join_path(tmp,
		'manifest.csv')}')
	rd := fn [tmp] (f string) string {
		return os.read_file(os.join_path(tmp, f)) or { '' }
	}
	return PtOut{r.exit_code, r.output, rd('gen.v'), rd('ports.v'), rd('sig.v'), rd('manifest.csv')}
}

fn same(src string) string {
	return src
}

// in_order asserts every step appears in `text`, each after the one before it
fn in_order(text string, steps []string) {
	mut at := -1
	for step in steps {
		i := text[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}

// the id and fingerprint loom2v gave parameter `idx`, from the glue
fn id_fp(glue string, idx int) (string, string) {
	a := glue.index('g_param.p[${idx}].id = ') or { return '', '' }
	b := glue.index('g_param.p[${idx}].fp = ') or { return '', '' }
	return glue[a..glue.index_after('\n', a) or { a }], glue[b..glue.index_after('\n', b) or { b }]
}

fn test_parameters_are_restored_before_the_kernel_and_bound_on_the_comm_thread() {
	o := pt_generate('wired', reads_params, pt_conn + pt_param)
	assert o.code == 0, o.out
	// the value types, and the In fields an FB reads them through (never an Out)
	in_order(o.sig, ['pub struct LoadCap {', 'iters u16', 'strict bool', 'pub struct Trim {', 'x i8'])
	in_order(o.ports, ['pub struct LoadSlowIn {', 'load_cap sig.LoadCap', 'trim sig.Trim', '}',
		'pub struct LoadSlowOut {'])
	assert !o.ports.all_after('pub struct LoadSlowOut {').all_before('}').contains('load_cap')
	// the handler reads each from its cell — every field, as the comm thread published it
	in_order(o.glue, ['fn handler_app_load_slow_on_100ms(', 'C.ioc_get(', '&load_cap_a, &load_cap_b)',
		'inp.load_cap.iters = u16(load_cap_a)', 'inp.load_cap.strict = load_cap_b != 0',
		'&trim_a, &trim_b)', 'inp.trim.x = i8(trim_a)', 'st.load_slow.on_100ms(inp, mut outp)'])
	// boot: the journal mounted, the parameter blocks kept by the prune, the table configured and
	// restored — publishing into the cells — all before the kernel starts
	in_order(o.glue, ['pub fn boot() {', 'C.ioc_pool_init()', 'g_nvm.mount()', 'if g_nvm.mounted {',
		'/* [[param]] LoadCap */', '/* [[param]] Trim */', 'g_nvm.prune(&keep[0], 2)',
		'g_param.p[0].did = u16(0x110) // LoadCap', 'g_param.p[0].fields[0] = param.Field{ // iters u16',
		'min:    i64(10)', 'max:    i64(1000)', 'def:    i64(500)',
		'g_param.p[0].fields[1] = param.Field{ // strict bool', 'max:    i64(1)', 'def:    i64(0)',
		'g_param.p[1].apply_reset = true', 'signed: true', 'min:    i64(-128)', 'def:    i64(-3)',
		'g_param.n = 2', 'g_param.publish = param_pub', 'g_param.restore(g_nvm.mounted)',
		'C._tx_initialize_kernel_enter()'])
	// every parameter's cell is the one its readers read, published only by the comm thread's table
	a := o.glue.all_after('mut load_cap_b := u32(0)\n\tC.ioc_get(').all_before(',')
	in_order(o.glue, ['fn param_pub(', '0 { C.ioc_pub(${a}, a, b) } // LoadCap', '1 { C.ioc_pub('])
	// the comm thread binds them once every DID is in the server, before the loop
	in_order(o.glue, ['fn comm_thread_entry(', 'g_diag.server.ndid = 3',
		'g_param.bind(mut g_diag.server, u16(0x112))', 'for {'])
	// the fixture runs NM: a parameter coded in bus sleep re-runs the flush choreography
	in_order(o.glue, ['g_diag.serve()', 'if g_param.take_wrote() && g_nm.state() == .bus_sleep {',
		'g_nvm.mark_clean()'])
	assert o.glue.contains('import comm.param')
	assert o.manifest.contains('LoadCap,0x110,'), o.manifest
	assert o.manifest.contains(',reset,x:i8:-128..127=-3'), o.manifest
}

// a block id follows the NAME and the fingerprint the LAYOUT: declaration order and a range move
// neither, a field type moves only the fingerprint — so the old record is found and refused
fn test_a_parameters_identity_is_its_name_and_its_layout() {
	o1 := pt_generate('id1', reads_params, pt_conn + pt_param)
	assert o1.code == 0, o1.out
	id0, fp0 := id_fp(o1.glue, 0)
	// the two declared the other way round (LoadCap is p[1] now), and LoadCap's range changed
	loadcap := pt_param.all_before('[[param]]\nname    = "Trim"')
	trim := '[[param]]\nname    = "Trim"' + pt_param.all_after('[[param]]\nname    = "Trim"').all_before('[[did]]')
	dids := '[[did]]' + pt_param.all_after('[[did]]')
	trim_first := '\n' + trim + loadcap.replace('min = 10, max = 1000', 'min = 0, max = 900') + dids
	o2 := pt_generate('id2', reads_params, pt_conn + trim_first)
	assert o2.code == 0, o2.out
	id1, fp1 := id_fp(o2.glue, 1)
	assert id1.all_after('= ') == id0.all_after('= '), 'the block moved with the declaration order or the range'
	assert fp1.all_after('= ') == fp0.all_after('= ')
	assert id0.all_after('= ') != fp0.all_after('= '), 'the fingerprint is the block id: a pin would check nothing'
	o3 := pt_generate('id3', reads_params, pt_conn + pt_param.replace('iters = "u16"', 'iters = "u32"'))
	assert o3.code == 0, o3.out
	id3, fp3 := id_fp(o3.glue, 0)
	assert id3.all_after('= ') == id0.all_after('= '), 'a layout change moved the block: the old record would be pruned, not refused'
	assert fp3.all_after('= ') != fp0.all_after('= '), 'a layout change kept the fingerprint: the old bytes would be read as the new layout'
	// the field ORDER is layout too: it is the order of the bytes in the record and the DID
	o4 := pt_generate('id4', reads_params, pt_conn + pt_param.replace('fields  = { iters = "u16", strict = "bool" }',
		'fields  = { strict = "bool", iters = "u16" }'))
	assert o4.code == 0, o4.out
	_, fp4 := id_fp(o4.glue, 0)
	assert fp4.all_after('= ') != fp0.all_after('= ')
}

fn test_what_generation_refuses() {
	cases := {
		'no nvm':           [pt_conn.replace('[nvm]\nmin_write_ms = 1000', '') + pt_param,
			'[[param]] needs [nvm]']
		'no did':           [pt_conn + pt_param.replace('param = "Trim"', 'bytes = "00"'),
			'"Trim" is coded through 0 [[did]]s']
		'two dids':         [pt_conn + pt_param + '\n[[did]]\nid = 0x0113\nparam = "Trim"\n',
			'"Trim" is coded through 2 [[did]]s']
		'unknown param':    [pt_conn + pt_param + '\n[[did]]\nid = 0x0113\nparam = "Nope"\n',
			'names parameter "Nope", which is not a [[param]]']
		'did with bytes':   [pt_conn + pt_param.replace('param = "Trim"', 'param = "Trim"\nbytes = "00"'),
			'its record is the parameter\'s, so `bytes`']
		'status written':   [pt_conn + pt_param.replace('param_status = true', 'param_status = true\nwrite = { security = 1 }'),
			'which a tester reads and never writes']
		'default outside':  [pt_conn + pt_param.replace('iters = 500', 'iters = 5'),
			'default iters = 5 is outside its range 10..1000']
		'range outside':    [pt_conn + pt_param.replace('max = 1000', 'max = 70000'),
			'is not inside u16\'s 0..65535']
		'range on a bool':  [pt_conn + pt_param.replace('range   = { iters = { min = 10, max = 1000 } }',
			'range   = { strict = { min = 0, max = 1 } }'), 'is a bool — it has no range']
		'no default':       [pt_conn + pt_param.replace('default = { x = -3 }', 'default = { }'),
			'default has no "x"']
		'float type':       [pt_conn + pt_param.replace('x = "i8" }\ndefault = { x = -3 }', 'x = "f32" }\ndefault = { x = 0 }'),
			'a parameter field is bool, u8, u16, u32, i8, i16 or i32']
		'three fields':     [pt_conn + pt_param.replace('fields  = { x = "i8" }\ndefault = { x = -3 }',
			'fields  = { x = "i8", y = "u8", z = "u8" }\ndefault = { x = -3, y = 0, z = 0 }'),
			'has 3 fields — a parameter has 1..2']
		'bad apply':        [pt_conn + pt_param.replace('apply   = "reset"', 'apply   = "later"'),
			'apply = "later"']
		'pin collision':    [pt_conn + pt_param.replace('apply   = "reset"', 'apply   = "reset"\nnvm_id  = 0x1234').replace('range   = {',
			'nvm_id  = 0x1234\nrange   = {'), 'collides with [[param]] "LoadCap"']
		'open in default':  [pt_conn + pt_param.replace('param = "Trim"\nwrite = { session = ["extended"], security = 1 }', 'param = "Trim"'),
			'codes parameter "Trim" from the default session with no 0x27 level']
		'default session':  [pt_conn + pt_param.replace('param = "Trim"\nwrite = { session = ["extended"], security = 1 }',
			'param = "Trim"\nwrite = { session = ["default", "extended"] }'), 'from the default session with no 0x27 level']
		'snake name':       [pt_conn + pt_param.replace('name    = "Trim"', 'name    = "trim_x"').replace('param = "Trim"',
			'param = "trim_x"'), 'name "trim_x" is not PascalCase']
		'camel field':      [pt_conn + pt_param.replace('x = "i8" }\ndefault = { x = -3 }', 'maxX = "i8" }\ndefault = { maxX = -3 }'),
			'field "maxX" is not a lower-case identifier']
		'signal clash':     [pt_conn + pt_param.replace('name    = "Trim"', 'name    = "Workload"').replace('param = "Trim"',
			'param = "Workload"'), 'and [[signal]] "Workload" are one identifier']
		'pin wraps':        [pt_conn + pt_param.replace('apply   = "reset"', 'apply   = "reset"\nnvm_id  = 0x100000001'),
			'nvm_id = 4294967297 is out of range']
		'no isotp':         [pt_conn.all_after('functional_id = 0x7DF') + pt_param.all_before('[[did]]'),
			'declare the diagnostic server\'s [isotp] connection']
	}
	for name, c in cases {
		o := pt_generate(name.replace(' ', '_'), reads_params, c[0])
		assert o.code != 0, 'loom2v accepted: ${name}'
		assert o.out.contains(c[1]), '${name}: ${o.out}'
	}
	// who reads it: nobody, a writer, an FB that writes it
	nobody := pt_generate('nobody', same, pt_conn + pt_param)
	assert nobody.code != 0 && nobody.out.contains('"LoadCap" is read by no FB handler'), nobody.out
	writer := pt_generate('writer', fn (s string) string {
		return reads_params(s).replace('writes    = ["Workload"]', 'writes    = ["Workload", "Trim"]')
	}, pt_conn + pt_param)
	assert writer.code != 0 && writer.out.contains('writes parameter "Trim" — a parameter is read-only'), writer.out
	// two reading threads: the cell has one reader context
	two := pt_generate('twothreads', fn (s string) string {
		mut t := reads_params(s)
		t = t.replace('  [[partition.thread]]\n  name     = "load_fast"\n  priority = 11\n',
			'  [[partition.thread]]\n  name     = "load_fast"\n  priority = 11\n\n  [[partition.thread]]\n  name     = "other"\n  priority = 12\n')
		return t.replace('name      = "LoadFast"\nthread    = "load_fast"\n  [[fb.handler]]\n  name      = "on_10ms"\n  period_ms = 10',
			'name      = "LoadFast"\nthread    = "other"\n  [[fb.handler]]\n  name      = "on_10ms"\n  period_ms = 10\n  reads     = ["Trim"]')
	}, pt_conn + pt_param)
	assert two.code != 0 && two.out.contains('parameter "Trim" is read on threads'), two.out
}

// a 0x2E service row gating the write is the gate a parameter DID without its own needs
fn test_the_service_row_can_be_the_gate() {
	row := '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n"0x27" = {}\n"0x2E" = { sessions = ["extended"], security = 1 }\n"0x3E" = {}\n'
	o := pt_generate('row_gate', reads_params, pt_conn + pt_param.replace('param = "Trim"\nwrite = { session = ["extended"], security = 1 }',
		'param = "Trim"') + row)
	assert o.code == 0, o.out
}

// with a persisted fault memory on an NM node, ONE in-sleep choreography covers both writers
fn test_one_sleep_choreography_for_the_fault_memory_and_the_parameters() {
	fault := '\n[[fault]]\nname     = "LoadImplausible"\ndtc      = 0xC40100\nfrom     = "LoadSlow.on_100ms"\ndebounce = { kind = "counter", fail = 3, pass = 3 }\n'
	o := pt_generate('with_faults', reads_params, pt_conn + pt_param + fault)
	assert o.code == 0, o.out
	in_order(o.glue, ['g_fmem.persist(t1, false)', 'param_wrote := g_param.take_wrote()',
		'if (g_fmem.wrote > 0 || param_wrote) && g_nm.state() == .bus_sleep {', 'g_nvm.mark_clean()'])
	assert o.glue.count('g_param.take_wrote()') == 1
	assert !o.glue.contains('if g_param.take_wrote() && g_nm.state()')
}

// on a [doip] node a parameter's DID is a state-changing write: it needs a 0x27 level (REQ-NET-012)
fn test_a_network_reachable_parameter_needs_its_own_unlock() {
	doip := '
[uds.services]
"0x10" = {}
"0x11" = { sessions = ["extended"], security = 1 }
"0x22" = {}
"0x27" = {}
"0x2E" = {}
"0x3E" = {}

[[did]]
id    = 0xF190
ascii = "BLOBLYH735THREADX"

[doip]
address         = "192.168.0.50"
logical_address = 0x07B0
'
	open := pt_param.replace('param = "Trim"\nwrite = { session = ["extended"], security = 1 }',
		'param = "Trim"\nwrite = { session = ["extended"] }')
	o := pt_generate('doip_open', reads_params, pt_conn + open + doip)
	assert o.code != 0
	assert o.out.contains('makes DID 0x111 writable from the network with no security level'), o.out
	ok := pt_generate('doip_gated', reads_params, pt_conn + pt_param + doip)
	assert ok.code == 0, ok.out
}
