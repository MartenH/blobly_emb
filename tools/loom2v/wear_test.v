module main

// @verifies REQ-NVM-010
import os
import time

// The journal's wear check (gen_wear.v): every writer — persisted signals, clean markers, the fault
// memory, the parameters — in one computation, refused at generation below `min_years` with each
// contributor's share named, printed otherwise. Runs the real generator: on testdata/threadx_node
// with a connection, a fault, parameters and [nvm] appended, and on system_full's lowered nodes.
const fixture_dir = os.join_path(@DIR, 'testdata', 'threadx_node')

const wt_bin = os.join_path(os.temp_dir(), 'loom2v_wear_${os.getpid()}_${time.now().unix_nano()}')

const wt_sysgen = os.join_path(os.temp_dir(), 'sysgen_wear_${os.getpid()}_${time.now().unix_nano()}')

// a node with a persisted fault memory (one snapshot DTC) and two parameters, on the NM fixture
const wt_cfg = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLY"

[[fault]]
name     = "LoadImplausible"
dtc      = 0xC40100
from     = "LoadSlow.on_100ms"
debounce = { kind = "counter", fail = 3, pass = 3 }
freeze   = [0xF190]

[[fault]]
name     = "LoadStuck"
dtc      = 0xC40101
from     = "LoadSlow.on_100ms"

[[param]]
name    = "LoadCap"
fields  = { iters = "u16" }
default = { iters = 500 }

[[param]]
name    = "Trim"
fields  = { x = "i8" }
default = { x = -3 }

[[did]]
id    = 0x0110
param = "LoadCap"
write = { session = ["extended"], security = 1 }

[[did]]
id    = 0x0111
param = "Trim"
write = { session = ["extended"], security = 1 }

[nvm]
min_write_ms = 1000
'

fn testsuite_begin() {
	for out, tool in {
		wt_bin:    'loom2v'
		wt_sysgen: 'sysgen'
	} {
		r := os.execute('${@VEXE} -enable-globals -o ${out} ${os.join_path(@VMODROOT, 'tools', tool)}')
		assert r.exit_code == 0, r.output
	}
}

fn testsuite_end() {
	os.rm(wt_bin) or {}
	os.rm(wt_sysgen) or {}
}

// one_thread: the fixture with every FB on its first thread (faults in a multi-thread partition
// are not generated), LoadSlow reading both parameters
fn one_thread(src string) string {
	mut s := src
	for t in ['load_mid', 'ctrl_slow'] {
		at := s.index('  [[partition.thread]]\n  name     = "${t}"') or { panic('no thread ${t}') }
		end := s.index_after('\n\n', at) or { panic('no end of thread ${t}') }
		s = s[..at] + s[end + 2..]
		s = s.replace('thread    = "${t}"', 'thread    = "load_fast"')
	}
	return s.replace('  reads     = ["LoadCmd"]\n  writes    = ["Workload"]', '  reads     = ["LoadCmd", "LoadCap", "Trim"]\n  writes    = ["Workload"]')
}

// wt_generate runs loom2v on the fixture with `extra` appended: the exit code and the output.
fn wt_generate(name string, extra string) (int, string) {
	tmp := os.join_path(os.temp_dir(), 'wear_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	src := os.read_file(os.join_path(fixture_dir, 'ecu.toml')) or { panic(err) }
	os.write_file(ecu, one_thread(src) + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(fixture_dir, 'bus.dbc'), dbc) or { panic(err) }
	r := os.execute('${wt_bin} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' + '${os.join_path(tmp, 'ports.v')} ${os.join_path(tmp, 'gen.v')}')
	return r.exit_code, r.output
}

// wear_report: the wear lines of a generator's output.
fn wear_report(out string) []string {
	mut lines := []string{}
	mut on := false
	for l in out.split_into_lines() {
		if l.contains('[nvm] wear') {
			on = true
		} else if on && !l.starts_with('loom2v:   ') && !l.starts_with('  ') {
			on = false
		}
		if on {
			lines << l
		}
	}
	return lines
}

// share: the records/h and percentage the report gives a contributor, '' when it names none.
fn share(report []string, what string) string {
	for l in report {
		if l.contains(what) {
			return l.all_after('${what}').all_after(': ').all_before(' —')
		}
	}
	return ''
}

// Fault and parameter traffic that wears the journal out is refused at generation, and the message
// names every contributor with its share — the fault memory and the parameters included, which the
// check did not see before (#371).
fn test_fault_and_parameter_traffic_past_the_budget_is_refused() {
	code, out := wt_generate('refused', wt_cfg + 'sector_records = 256\n\n[nvm.assume]\ncycles_per_day = 2400\nclears_per_day = 240\ncodings_per_day = 24000\n')
	assert code != 0, 'a journal worn out in under a year was generated:\n${out}'
	assert out.contains('[nvm] wear check failed'), out
	report := wear_report(out)
	// every line carries the generator's prefix: syscheck keeps only those, and must keep the shares
	assert report.len > 4 && report.all(it.contains('loom2v:')), out
	for what in ['clean markers', 'fault memory status image', 'fault memory snapshots',
		'parameters (2)'] {
		s := share(report, what)
		assert s.contains('records/h (') && s.contains('%)'), '${what} has no share in:\n${out}'
	}
	assert out.contains('2400 operation cycles/day, 24 ECUResets/day (default), 240 0x14 clears/day, 24 0x85 changes/day (default), 24000 0x2E codings/day'), out
	// the parameters' share is theirs: one record per coding, 24000 a day
	assert share(report, 'parameters (2)').starts_with('1000 records/h'), out
	// the same node at the default (conservative) rates and a full sector lasts: printed, not refused
	c2, o2 := wt_generate('kept', wt_cfg)
	assert c2 == 0, o2
	r2 := wear_report(o2)
	assert r2.len > 0 && r2[0].contains('years at 10000 cycles'), o2
	for what in ['clean markers', 'fault memory status image', 'fault memory snapshots',
		'parameters (2)'] {
		assert share(r2, what) != '', '${what} missing from the report:\n${o2}'
	}
	assert o2.contains('debounce counters are never written'), o2
}

// The assumptions are the vehicle's and stated in [nvm.assume]: an unknown key is refused, a key
// out of range too, and the table alone switches no journal on.
fn test_assumptions_are_checked() {
	c1, o1 := wt_generate('typo', wt_cfg + '\n[nvm.assume]\ncycle_per_day = 10\n')
	assert c1 != 0 && o1.contains('[nvm.assume] unknown key "cycle_per_day"'), o1
	c2, o2 := wt_generate('zero', wt_cfg + '\n[nvm.assume]\ncycles_per_day = 0\n')
	assert c2 != 0 && o2.contains('cycles_per_day') && o2.contains('out of range'), o2
	// the rates alone declare no storage: the fault memory still asks for [nvm]
	c3, o3 := wt_generate('alone', wt_cfg.replace('[nvm]\nmin_write_ms = 1000\n', '') +
		'\n[nvm.assume]\ncycles_per_day = 10\n')
	assert c3 != 0 && o3.contains('needs [nvm]'), o3
}

// system_full_reports lowers system_full and runs loom2v on each node with a journal: node -> its
// wear report.
fn system_full_reports() map[string][]string {
	tmp := os.join_path(os.temp_dir(), 'wear_system_full_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	sys := os.join_path(@VMODROOT, 'examples', 'system_full', 'system.toml')
	lower := os.execute('${wt_sysgen} ${sys} --out ${tmp}')
	assert lower.exit_code == 0, lower.output
	mut out := map[string][]string{}
	for node, dbc in {
		'domain': 'compute'
		'zone_a': 'edge'
	} {
		toml_path := os.join_path(tmp, 'gen-' + node + '.toml')
		dbc_path := os.join_path(tmp, dbc + '.dbc')
		outs := ['s.v', 'p.v', 'g.v'].map(os.join_path(tmp, it)).join(' ')
		r := os.execute('${wt_bin} ${toml_path} ${dbc_path} ${outs}')
		assert r.exit_code == 0, '${node}: ${r.output}'
		out[node] = wear_report(r.output)
	}
	return out
}

// system_full's two journals pass at the default assumptions, and their numbers are printed here
// and pinned: a change to the model, or to a node's traffic, moves them visibly.
fn test_system_full_lasts_and_its_numbers_are_printed() {
	reports := system_full_reports()
	for node in ['domain', 'zone_a'] {
		r := reports[node] or { []string{} }
		println('${node}:')
		for l in r {
			println('  ${l.all_after('loom2v: ')}')
		}
	}
	// domain: DriveMode floored at 10 s, on an NM node — each put that can land in bus sleep lays a
	// clean marker beside it
	d := reports['domain'] or { []string{} }
	assert d.len > 0 && d[0].contains('750 records/h') && d[0].contains('12.5 years'), d.join('\n')
	assert share(d, 'signal "DriveMode" (persist = "now")').starts_with('375 records/h'), d.join('\n')
	assert share(d, 'clean markers').starts_with('375 records/h'), d.join('\n')
	// zone_a: a power-cycle node — its persisted fault memory, its parameter, its resets' markers
	z := reports['zone_a'] or { []string{} }
	assert z.len > 0 && z[0].contains('285 records/h') && z[0].contains('16.4 years'), z.join('\n')
	assert share(z, 'fault memory status image (42 B = 3 records)').starts_with('267 records/h'), z.join('\n')
	assert share(z, 'fault memory snapshots').starts_with('16 records/h'), z.join('\n')
	assert share(z, 'parameters (1)').starts_with('1 records/h'), z.join('\n')
	assert share(z, 'clean markers').starts_with('1 records/h'), z.join('\n')
}
