module main

fn test_an_unread_parameter_is_blanked_and_a_read_one_kept() {
	src := [
		'fn shell_ps_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {',
		'\tn := C.shell_ps(&rsp.buf[0], 520)',
		'}',
		'fn nvm_fl_erase(ctx voidptr, addr u32, size u32) bool {',
		'\treturn C.bflash_erase(addr, size) != 0',
		'}',
	]
	assert blank_unused_params(src) == [
		'fn shell_ps_cmd(_ &u8, _ int, _ u64, mut rsp shell.Rsp) {',
		'\tn := C.shell_ps(&rsp.buf[0], 520)',
		'}',
		'fn nvm_fl_erase(_ voidptr, addr u32, size u32) bool {',
		'\treturn C.bflash_erase(addr, size) != 0',
		'}',
	]
}

// a name inside a longer identifier is not a use; a method's receiver is not a parameter; a
// function-typed parameter's own commas do not split it; an empty body reads nothing
fn test_the_cases_a_naive_match_gets_wrong() {
	src := [
		'fn (mut m Mod) hook(now u64, cb fn (a int, b int), n int) {',
		'\tm.now_us = n',
		'}',
		'fn net_pass(now u64) {}',
		'fn C.ioc_pub(int, u32, u32)',
		'@[export: \'tx_application_define\']',
		'fn tx_application_define(first_unused voidptr) {',
		'\tC._tx_thread_create(first_unused)',
		'}',
	]
	assert blank_unused_params(src) == [
		'fn (mut m Mod) hook(_ u64, _ fn (a int, b int), n int) {',
		'\tm.now_us = n',
		'}',
		'fn net_pass(_ u64) {}',
		'fn C.ioc_pub(int, u32, u32)',
		'@[export: \'tx_application_define\']',
		'fn tx_application_define(first_unused voidptr) {',
		'\tC._tx_thread_create(first_unused)',
		'}',
	]
}
