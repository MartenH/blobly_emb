module sysmodel

import os

// @verifies REQ-NET-012 REQ-DIAG-126
// The system check's half of the bench-key rule for a node that unlocks by 0x29 (check_doip, through
// doipcfg.bench_key_refusal): parse_node_view reads whether its [uds] auth_keys name "reference", the
// dev tester key, and a DoIP node doing so is refused without `allow_bench_key`, accepted with it; a
// node whose keys are all its testers' own is refused for an `allow_bench_key` that means nothing.
// Runs on a copy of examples/system_full with sysnode (the DoIP gateway) switched to authentication.

const other_key = '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8'

fn auth_fixture(auth_keys string) string {
	dir := os.join_path(os.temp_dir(), 'sysmodel_auth_${os.getpid()}_${auth_keys.len}')
	src := os.join_path(@VMODROOT, 'examples', 'system_full')
	os.mkdir_all(dir) or { panic(err) }
	for f in os.ls(src) or { [] } {
		if f.ends_with('.dbc') {
			os.cp(os.join_path(src, f), os.join_path(dir, f)) or { panic(err) }
		}
	}
	for n in os.ls(os.join_path(src, 'nodes')) or { [] } {
		e := os.join_path(src, 'nodes', n, 'ecu.toml')
		if os.exists(e) {
			os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
			mut text := os.read_file(e) or { panic(err) }
			if n == 'sysnode' {
				assert text.contains('security_key      = "reference"')
				text = text.replace('security_key      = "reference"', 'access    = "authentication"\nauth_keys = { ${auth_keys} }')
			}
			os.write_file(os.join_path(dir, 'nodes', n, 'ecu.toml'), text) or { panic(err) }
		}
	}
	return dir
}

// errors: what syscheck reports for system_full's system.toml with `edit` applied, in `dir`
fn errors(dir string, edit fn (string) string) []string {
	text := os.read_file(os.join_path(@VMODROOT, 'examples', 'system_full', 'system.toml')) or {
		panic(err)
	}
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, edit(text)) or { panic(err) }
	mut s := parse_system(path) or { return [err.msg()] }
	mut out := s.load_nodes_partial()
	for i in validate_system_gen(s) {
		if i.severity == .error {
			out << i.msg
		}
	}
	return out
}

fn bench_errors(errs []string) []string {
	return errs.filter(it.contains('bench') || it.contains('PUBLIC'))
}

fn test_the_dev_tester_key_over_doip_is_allowed_only_by_name() {
	same := fn (t string) string {
		return t
	}
	no_allow := fn (t string) string {
		assert t.contains(', allow_bench_key = true }')
		return t.replace(', allow_bench_key = true }', ' }')
	}
	// "reference" for level 1: the fixture's allow_bench_key = true accepts it, and without it, refused
	dir := auth_fixture('"1" = "reference"')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut s := parse_system_at(dir, same)
	s.load_nodes_partial()
	sys := s.nodes.filter(it.name == 'sysnode')
	assert sys.len == 1 && sys[0].view.uds_auth_reference, 'parse_node_view did not read the reference auth key'
	assert bench_errors(errors(dir, same)) == []
	refused := bench_errors(errors(dir, no_allow))
	assert refused.len == 1 && refused[0].contains('auth_keys names "reference"'), '${refused}'
	// the tester's own key: no bench key, so allow_bench_key means nothing
	own := auth_fixture('"1" = "${other_key}"')
	defer {
		os.rmdir_all(own) or {}
	}
	mut o := parse_system_at(own, same)
	o.load_nodes_partial()
	assert !o.nodes.filter(it.name == 'sysnode')[0].view.uds_auth_reference
	meaningless := bench_errors(errors(own, same))
	assert meaningless.len == 1 && meaningless[0].contains('it would mean nothing'), '${meaningless}'
	assert bench_errors(errors(own, no_allow)) == []
}

fn parse_system_at(dir string, edit fn (string) string) System {
	text := os.read_file(os.join_path(@VMODROOT, 'examples', 'system_full', 'system.toml')) or {
		panic(err)
	}
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, edit(text)) or { panic(err) }
	return parse_system(path) or { panic(err) }
}
