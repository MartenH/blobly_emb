module sysmodel

import os

// make hands its tools over through tool_dir_env; a binary it does not hold, or no directory at
// all, falls back to building (prebuilt_tool answers none)
fn test_a_prebuilt_tool_is_used_only_where_make_put_one() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_tool_dir_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
		os.unsetenv(tool_dir_env)
	}
	os.write_file(os.join_path(dir, '.tool-ecucheck'), '') or { panic(err) }
	os.unsetenv(tool_dir_env)
	assert prebuilt_tool('ecucheck') == none
	os.setenv(tool_dir_env, dir, true)
	assert prebuilt_tool('ecucheck') or { '' } == os.join_path(dir, '.tool-ecucheck')
	assert prebuilt_tool('loom2v') == none
}

// every tool the system checks run is one the root Makefile hands over (SYSTEM_GATE_TOOLS): a tool
// left off that list would be read from BLOB_TOOL_DIR without make having kept it current
fn test_every_tool_the_checks_run_is_handed_over_by_make() {
	mk := os.read_file(os.join_path(@VMODROOT, 'Makefile')) or { panic(err) }
	gate := mk.split_into_lines().filter(it.starts_with('SYSTEM_GATE_TOOLS ='))
	assert gate.len == 1, 'the root Makefile defines SYSTEM_GATE_TOOLS once'
	mut run := 0
	for f in os.ls(os.join_path(@VMODROOT, 'tools', 'sysmodel')) or { panic(err) } {
		if !f.ends_with('.v') || f.ends_with('_test.v') {
			continue
		}
		src := os.read_file(os.join_path(@VMODROOT, 'tools', 'sysmodel', f)) or { panic(err) }
		for chunk in src.split("run_tool('")[1..] {
			name := chunk.all_before("'")
			run++
			assert gate[0].contains('\$(TOOL_${name})'), '${f} runs ${name}, which SYSTEM_GATE_TOOLS does not list'
		}
	}
	assert run >= 4, 'found only ${run} run_tool calls'
}
