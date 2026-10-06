module main

import os

// [display] (gen_display.v): the display thread the generator creates, where it sits among the
// image's threads, what gen/loom_build.mk links for it, and what it refuses. Runs the real
// generator on testdata/threadx_node, whose [trace] is cut ([display] refuses it); a refusal is a
// panic, which cannot be caught in-process.

const display_fixture = os.join_path(@DIR, 'testdata', 'threadx_node')

fn display_loom2v() string {
	bin := os.join_path(os.temp_dir(), 'loom2v_display_target_${os.getpid()}')
	if !os.exists(bin) {
		r := os.execute('${@VEXE} -enable-globals -o ${bin} ${os.join_path(@VMODROOT, 'tools',
			'loom2v')}')
		assert r.exit_code == 0, r.output
	}
	return bin
}

// without_trace: the fixture's config with its [trace] table cut (it runs to the next table)
fn without_trace(src string) string {
	start := src.index('\n[trace]\n') or { panic('fixture has no [trace]') }
	end := src.index_after('\n[', start + 1) or { src.len }
	return src[..start] + src[end..]
}

// gen_display runs loom2v on the fixture (its [trace] cut unless keep_trace) with `extra`
// appended; returns the exit code, the output, the glue and gen/loom_build.mk.
fn gen_display(name string, keep_trace bool, extra string) (int, string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'display_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	src := os.read_file(os.join_path(display_fixture, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, (if keep_trace { src } else { without_trace(src) }) + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(display_fixture, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${display_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }, os.read_file(os.join_path(tmp,
		'loom_build.mk')) or { '' }
}

// created_prios: the priority of every thread tx_application_define creates through
// _tx_thread_create (the second line of each call carries `u32(prio), u32(prio)`)
fn created_prios(glue string) []int {
	mut out := []int{}
	lines := glue.split_into_lines()
	for i, l in lines {
		if !l.trim_space().starts_with('C._tx_thread_create(') || i + 1 >= lines.len {
			continue
		}
		parts := lines[i + 1].split('u32(')
		// &stack, u32(len), u32(prio), u32(prio), u32(0), u32(1)
		assert parts.len >= 4, lines[i + 1]
		out << parts[2].all_before(')').int()
	}
	return out
}

const display_section = '
[display]
ui = "screen.c"
'

fn test_the_display_thread_runs_below_every_other_thread() {
	code, out, glue, _ := gen_display('below', false, display_section)
	assert code == 0, out
	assert glue.contains('fn C.display_thread_create(u32)')
	call := glue.split_into_lines().filter(it.contains('C.display_thread_create(u32('))
	assert call.len == 1, call.str()
	prio := call[0].all_after('C.display_thread_create(u32(').all_before(')').int()
	others := created_prios(glue)
	assert others.len > 0
	for p in others {
		assert prio > p, 'display at ${prio} is not below a thread at ${p}'
	}
	assert prio <= 30 // 31 is the idle thread's (display.c)
}

fn test_the_build_links_the_boards_display_and_the_nodes_screen() {
	code, out, _, mk := gen_display('mk', false, display_section)
	assert code == 0, out
	assert mk.contains('include \$(REPO)/boards/\$(BOARD)/display.mk'), mk
	// a board without a display stops the build by name, before the include fails obscurely
	assert mk.contains('\$(error [display]: board \$(BOARD) has no display'), mk
	assert mk.contains('LOOM_DISPLAY_SRCS = \$(DISPLAY_SRCS) screen.c \$(LVGL_A)'), mk
	assert mk.contains('LOOM_DISPLAY_DEFS = \$(DISPLAY_CFLAGS)'), mk
}

fn test_a_node_without_a_display_links_none() {
	code, out, glue, mk := gen_display('none', false, '')
	assert code == 0, out
	assert !glue.contains('display_thread_create')
	// defined empty: every ThreadX Makefile lists them (threadx_makefiles_test.v)
	assert mk.contains('LOOM_DISPLAY_SRCS :=\nLOOM_DISPLAY_DEFS :=\n'), mk
	assert !mk.contains('display.mk'), mk
}

fn test_a_display_with_trace_is_refused() {
	code, out, _, _ := gen_display('trace', true, display_section)
	assert code != 0 && out.contains('[display] with [trace]'), out
}

fn test_a_display_without_its_screen_is_refused() {
	code, out, _, _ := gen_display('noui', false, '\n[display]\n')
	assert code != 0 && out.contains('[display] needs `ui`'), out
	code2, out2, _, _ := gen_display('badui', false, '\n[display]\nui = "screen.v"\n')
	assert code2 != 0 && out2.contains('a C file name'), out2
}

fn test_an_unknown_display_key_is_refused() {
	code, out, _, _ := gen_display('key', false, '\n[display]\nui = "screen.c"\nfps = 30\n')
	assert code != 0 && out.contains('[display] unknown key "fps"'), out
}
