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

// the block id loom2v gave parameter `idx`, and what its record header is made of — the field
// count, each field's width / signedness / bool, the version — from the glue
fn id_header(glue string, idx int) (string, string) {
	a := glue.index('g_param.p[${idx}].id = ') or { return '', '' }
	id := glue[a..glue.index_after('\n', a) or { a }]
	mut h := []string{}
	for l in glue.split_into_lines() {
		t := l.trim_space()
		if t.starts_with('g_param.p[${idx}].nfields') || t.starts_with('g_param.p[${idx}].version') {
			h << t.all_before(' //')
		}
	}
	block := glue.all_after('g_param.p[${idx}].nfields').all_before('g_param.p[${idx + 1}].did').all_before('g_param.n =')
	for l in block.split_into_lines() {
		t := l.trim_space()
		if t.starts_with('width:') || t.starts_with('signed:') || t.starts_with('boolean:') {
			h << t
		}
	}
	return id, h.join(';')
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

// the block follows the NAME; the record header is the STRUCTURE, exactly. Declaration order, a
// range and a field's name move neither; a type, the order, or a version bump changes the header
fn test_a_parameters_identity_is_its_name_and_its_exact_header() {
	o1 := pt_generate('id1', reads_params, pt_conn + pt_param)
	assert o1.code == 0, o1.out
	id0, h0 := id_header(o1.glue, 0)
	assert h0 == 'g_param.p[0].nfields = 2;width:  2;width:  1;boolean: true', h0
	// declared the other way round (LoadCap is p[1] now), its range changed, a field renamed
	loadcap := pt_param.all_before('[[param]]\nname    = "Trim"')
	trim := '[[param]]\nname    = "Trim"' + pt_param.all_after('[[param]]\nname    = "Trim"').all_before('[[did]]')
	dids := '[[did]]' + pt_param.all_after('[[did]]')
	moved := '\n' + trim + loadcap.replace('min = 10, max = 1000', 'min = 0, max = 900').replace('iters', 'count') + dids
	o2 := pt_generate('id2', reads_params, pt_conn + moved)
	assert o2.code == 0, o2.out
	id1, h1 := id_header(o2.glue, 1)
	assert id1.all_after('= ') == id0.all_after('= '), 'the block moved with the declaration order, the range or a field name'
	assert h1.replace('[1]', '[0]') == h0, 'a rename or a range changed the header: the coding would be lost'
	for name, edit in {
		'type':    pt_param.replace('iters = "u16"', 'iters = "i16"')
		'order_of_two_types': pt_param.replace('fields  = { iters = "u16", strict = "bool" }', 'fields  = { strict = "bool", iters = "u16" }')
		'version': pt_param.replace('range   = {', 'version = 1\nrange   = {')
	} {
		o := pt_generate('id_${name}', reads_params, pt_conn + edit)
		assert o.code == 0, o.out
		id, h := id_header(o.glue, 0)
		assert id.all_after('= ') == id0.all_after('= '), '${name} moved the block: the old record would be pruned, not refused'
		assert h != h0, '${name} left the header as it was: the old bytes would be read under it'
	}
	// POSITIONAL: two fields of ONE type declared the other way round leave the header as it was —
	// the values are taken by position — and only a version bump says otherwise
	two := pt_param.replace('fields  = { iters = "u16", strict = "bool" }', 'fields  = { iters = "u16", cap = "u16" }').replace('default = { iters = 500, strict = false }',
		'default = { iters = 500, cap = 7 }')
	oa := pt_generate('pos_a', reads_params, pt_conn + two)
	ob := pt_generate('pos_b', reads_params, pt_conn + two.replace('fields  = { iters = "u16", cap = "u16" }',
		'fields  = { cap = "u16", iters = "u16" }'))
	oc := pt_generate('pos_c', reads_params, pt_conn + two.replace('fields  = { iters = "u16", cap = "u16" }',
		'fields  = { cap = "u16", iters = "u16" }').replace('range   = {', 'version = 1\nrange   = {'))
	assert oa.code == 0 && ob.code == 0 && oc.code == 0, oa.out + ob.out + oc.out
	_, ha := id_header(oa.glue, 0)
	_, hb := id_header(ob.glue, 0)
	_, hc := id_header(oc.glue, 0)
	assert ha == hb, 'a same-type reorder changed the header: ${ha} / ${hb}'
	assert hc != ha, 'a version bump left the header as it was'
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
		'scalar range':     [pt_conn + pt_param.replace('range   = { iters = { min = 10, max = 1000 } }', 'range   = { iters = 100 }'),
			'range "iters" must be { min, max }']
		'range not table':  [pt_conn + pt_param.replace('range   = { iters = { min = 10, max = 1000 } }', 'range   = 100'),
			'range must be a table of fields']
		'bad version':      [pt_conn + pt_param.replace('range   = {', 'version = 300\nrange   = {'),
			'version = 300 is out of range']
		'duplicate did':    [pt_conn + pt_param + '\n[[did]]\nid = 0x0111\nbytes = "00"\nwrite = { session = ["default"] }\n',
			'[[did]] 0x111 is declared twice']
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

// the block is ASSIGNED: the parameter's DID (or a pin), never a hash of its name. Firmware A's
// Param116 retired and firmware B's Param506 added — names whose old 16-bit hash was one block —
// land on their own DIDs' blocks, so B can never inherit A's coded bytes; and a parameter renamed on
// its DID keeps its block (and, its header unchanged, its coding)
fn test_a_parameters_block_is_its_did() {
	a := pt_generate('blk_a', reads_params, pt_conn + pt_param)
	assert a.code == 0, a.out
	id_a, _ := id_header(a.glue, 0)
	assert id_a.all_after('= ').starts_with('u16(0x110)'), id_a // LoadCap on DID 0x0110
	id_t, _ := id_header(a.glue, 1)
	assert id_t.all_after('= ').starts_with('u16(0x111)'), id_t
	retired := pt_param.replace('"LoadCap"', '"Param116"')
	added := pt_param.replace('"LoadCap"', '"Param506"').replace('id    = 0x0110', 'id    = 0x0120')
	ra := pt_generate('blk_retired', fn (s string) string {
		return reads_params(s).replace('"LoadCap"', '"Param116"')
	}, pt_conn + retired)
	rb := pt_generate('blk_added', fn (s string) string {
		return reads_params(s).replace('"LoadCap"', '"Param506"')
	}, pt_conn + added)
	assert ra.code == 0 && rb.code == 0, ra.out + rb.out
	ida, _ := id_header(ra.glue, 0)
	idb, _ := id_header(rb.glue, 0)
	assert ida.all_after('= ').starts_with('u16(0x110)') && idb.all_after('= ').starts_with('u16(0x120)'), '${ida} / ${idb}'
	// a rename on the same DID keeps the block
	assert ida.all_after('= ') == id_a.all_after('= ')
	// a pin overrides the DID
	pinned := pt_generate('blk_pin', reads_params, pt_conn + pt_param.replace('apply   = "reset"', 'apply   = "reset"\nnvm_id  = 0x1234'))
	assert pinned.code == 0, pinned.out
	idp, _ := id_header(pinned.glue, 1)
	assert idp.all_after('= ').starts_with('u16(0x1234)'), idp
}

// an id is read whole and held to its range BEFORE anything narrows it: 0x10110 is not the DID
// 0x0110 (it would have collided with it at run time and bound the parameter to the weaker row),
// and a CAN id past 32 bits is not its low half
fn test_ids_are_bounded_where_they_are_read() {
	cases := {
		'did_wide':     [pt_conn + pt_param + '\n[[did]]\nid = 0x10110\nbytes = "00"\n', '[[did]] (a 16-bit data identifier) id = 0x10110 is out of range']
		'isotp_wide':   [pt_conn.replace('rx_id         = 0x7B0', 'rx_id         = 0x1000007B0') + pt_param, '[isotp] rx_id = 0x1000007b0 is out of range']
		'did_ffff':     [pt_conn + pt_param.replace('id    = 0x0111\nparam = "Trim"', 'id    = 0xFFFF\nparam = "Trim"'), 'is coded on DID 0xFFFF, which the journal reserves']
	}
	for name, c in cases {
		o := pt_generate(name, reads_params, c[0])
		assert o.code != 0, 'loom2v accepted: ${name}'
		assert o.out.contains(c[1]), '${name}: ${o.out}'
	}
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
