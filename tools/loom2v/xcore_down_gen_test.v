module main

import os
import tools.sysmodel

// @verifies REQ-INV-006
// Owner -> satellite signals end to end: loom2v run on a scratch copy of examples/h755_threadx
// (an owner with a generated CM4 image) with signals added in each shape — a received signal read
// on both cores, an owner FB output in the wider lane types, a wide satellite signal an owner FB
// reads — and the one refusal that needs the whole model. Then the generated lane code itself is
// compiled and run, since no committed image carries f32/f64/signed/64-bit lanes.

const owner_ex = os.join_path(@VMODROOT, 'examples', 'h755_threadx')

struct GenRun {
	code   int
	output string
	owner  string // the owner's gen/loom_gen.v
	sat    string // the satellite image's gen/loom_gen.v
	header string // gen/xcore_gen.h
	build  string // the satellite image's gen/loom_build.mk
}

// gen_scratch copies the owner example into a fresh directory, edits its ecu.toml, runs loom2v
fn gen_scratch(name string, edit fn (string) string) GenRun {
	tmp := os.join_path(os.vtmp_dir(), 'xdown_gen_${name}_${os.getpid()}')
	os.rmdir_all(tmp) or {}
	ex := os.join_path(tmp, 'h755_threadx')
	os.mkdir_all(ex) or { panic(err) }
	src := os.read_file(os.join_path(owner_ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(ex, 'ecu.toml')
	os.write_file(ecu, edit(src)) or { panic(err) }
	os.cp(os.join_path(owner_ex, 'bus.dbc'), os.join_path(ex, 'bus.dbc')) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	bin := sysmodel.tool_binary('loom2v') or { panic(err) }
	r := os.exec([bin, ecu, os.join_path(ex, 'bus.dbc'), os.join_path(tmp, 'sig.v'), os.join_path(tmp,
		'ports.v'), glue, os.join_path(tmp, 'manifest.csv')])
	sat := os.join_path(tmp, 'h755_m4_app', 'gen')
	out := GenRun{
		code:   r.exit_code
		output: r.output
		owner:  os.read_file(glue) or { '' }
		sat:    os.read_file(os.join_path(sat, 'loom_gen.v')) or { '' }
		header: os.read_file(os.join_path(tmp, 'xcore_gen.h')) or { '' }
		build:  os.read_file(os.join_path(sat, 'loom_build.mk')) or { '' }
	}
	os.rmdir_all(tmp) or {}
	return out
}

fn must_replace(s string, old string, new string) string {
	assert s.count(old) == 1, 'anchor not unique: ${old}'
	return s.replace(old, new)
}

// three crossings at once: Command (a received frame) read by Governor AND the CM4's M4Load;
// Tune (f32/i16/u64) from Governor to the CM4; M4Wide (u32/i32/f64) from the CM4 to LoadFast
fn three_ways(src string) string {
	mut s := must_replace(src, 'writes    = ["M4Count"]', 'reads     = ["Command", "Tune"]\nwrites    = ["M4Count", "M4Wide"]')
	s = must_replace(s, '  writes    = ["LoadCmd"]', '  writes    = ["LoadCmd", "Tune"]')
	s = must_replace(s, '  name      = "on_10ms"\n  period_ms = 10\n', '  name      = "on_10ms"\n  period_ms = 10\n  reads     = ["M4Wide"] # trailing comment ends the nested table (vlang/v#27684)\n')
	s += '\n[[signal]]\nname   = "Tune"\nfields = { gain = "f32", bias = "i16", big = "u64" }\nfrom   = "app"\nto     = "m4"\n'
	s += '\n[[signal]]\nname   = "M4Wide"\nfields = { a = "u32", b = "i32", c = "f64" }\nfrom   = "m4"\nto     = "app"\n'
	return s
}

fn test_signals_cross_both_ways_in_one_generated_node() {
	r := gen_scratch('both', three_ways)
	assert r.code == 0, r.output
	// contract: the down channels in the owner window, Command one lean lane, Tune four lanes
	assert r.header.contains('#define XCORE_OW_COMMAND_OFF 0u')
	assert r.header.contains('#define XCORE_OW_COMMAND_WORDS 1u')
	assert r.header.contains('#define XCORE_OW_TUNE_OFF 64u')
	assert r.header.contains('#define XCORE_OW_TUNE_WORDS 4u')
	assert r.header.contains('#define XCORE_XW_M4_WIDE_WORDS 4u') // u32 + i32 + f64 (two)
	// owner: boot brings the window up before the satellite is released
	b := r.owner.index('\tC.xcore_owner_begin()') or { -1 }
	i := r.owner.index('C.xcore_ow_init(u32(64), u32(4)) // Tune') or { -1 }
	c := r.owner.index('\tC.xcore_owner_commit()') or { -1 }
	rel := r.owner.index('\tC.xcore_clocks_ready()') or { -1 }
	assert b >= 0 && b < i && i < c && c < rel
	// owner: Command still reaches Governor through its IOC cell, and the CM4 through its channel
	assert r.owner.contains('C.xcore_opub_n(u32(0), &g_rx_last) // Command -> the satellite')
	assert r.owner.contains('C.ioc_get(')
	// owner: Tune packed by its writer, M4Wide read through the thread's own reader state
	assert r.owner.contains('xdown_pub_tune(outp.tune)')
	assert r.owner.contains('l[0] = xlane_f32_bits(v.gain)')
	assert r.owner.contains('xr_m4_wide [5]u32')
	assert r.owner.contains('inp.m4_wide.c = xlane_f64_from(')
	// satellite: gated reads of both down channels into its thread state, the reader linked
	assert r.sat.contains('xr_command [3]u32')
	assert r.sat.contains('if C.xcore_down_read(u32(64), u32(4), &st.xr_tune[0]) != 0 {')
	assert r.sat.contains('inp.tune.big = (u64(st.xr_tune[5]) << 32) | u64(st.xr_tune[4])')
	assert r.sat.contains('inp.tune.bias = i16(st.xr_tune[3])')
	assert r.sat.contains('fn xlane_f32_from(l u32) f32')
	assert r.build.contains(r'LOOM_GLUE_SRCS = $(BOARD_XCORE_SAT)')
}

fn test_a_second_owner_writer_thread_is_refused_end_to_end() {
	r := gen_scratch('writers', fn (src string) string {
		s := three_ways(src)
		return must_replace(s, '  name      = "on_20ms"\n  period_ms = 20\n', '  name      = "on_20ms"\n  period_ms = 20\n  writes    = ["Tune"] # trailing comment ends the nested table (vlang/v#27684)\n')
	})
	assert r.code != 0
	assert r.output.contains('cross-core signal "Tune" is written from 2 threads')
}

fn test_the_unchanged_example_generates_no_owner_window() {
	r := gen_scratch('plain', fn (src string) string {
		return src
	})
	assert r.code == 0, r.output
	assert !r.header.contains('XCORE_OW_')
	assert !r.owner.contains('xcore_owner_begin')
	assert r.build.contains('LOOM_GLUE_SRCS :=')
}

// the generated encode and decode, compiled and run on extreme values of every lane type
fn test_generated_lane_code_round_trips_every_type() {
	si := SigInfo{
		name:   'All'
		fields: [
			SigField{'a', 'u8'},
			SigField{'b', 'u16'},
			SigField{'c', 'u32'},
			SigField{'d', 'i8'},
			SigField{'e', 'i16'},
			SigField{'f', 'i32'},
			SigField{'g', 'f32'},
			SigField{'h', 'u64'},
			SigField{'i', 'i64'},
			SigField{'j', 'f64'},
			SigField{'k', 'bool'},
			SigField{'status', 'RxStatus'},
		]
	}
	n := sig_lanes(si)
	assert n == 15
	mut p := ['module main', '', 'enum RxStatus as u8 {', '\tnever_received', '\tok', '\ttimeout',
		'\tintegrity', '}', '', 'struct All {', 'mut:']
	for fld in si.fields {
		p << '\t${fld.name} ${fld.typ}'
	}
	p << '}'
	p << xlane_helpers([si]).map(it.replace('sig.', '')) // this program is its own sig module
	p << ''
	p << 'fn main() {'
	p << '\tv := All{a: 255, b: 65535, c: 4294967295, d: -128, e: -32768, f: -2147483648, g: -1.5e-30, h: 18446744073709551615, i: -9223372036854775807 - 1, j: -2.5e300, k: true, status: .integrity}'
	p << '\tmut l := [${n}]u32{}'
	p << lane_pack_lines(si, 'v', 'l', '\t')
	p << '\tmut st := [${n + 2}]u32{}'
	p << '\tfor x in 0 .. ${n} {'
	p << '\t\tst[2 + x] = l[x]'
	p << '\t}'
	p << '\tmut w := All{}'
	p << lane_unpack_lines(si, 'st', 2, 'w', false, '\t')
	p << '\tassert w == v'
	p << "\tprintln('round trip ok')"
	p << '}'
	dir := os.join_path(os.vtmp_dir(), 'xlane_rt_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	src := os.join_path(dir, 'rt.v')
	os.write_file(src, p.join('\n') + '\n') or { panic(err) }
	r := os.exec([@VEXE, '-nocache', 'run', src])
	os.rmdir_all(dir) or {}
	assert r.exit_code == 0, r.output
	assert r.output.contains('round trip ok')
}
