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
