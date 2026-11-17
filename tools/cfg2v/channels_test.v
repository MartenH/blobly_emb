module main

import os
import tools.sysmodel

// The IOC channel namespace cfg2v emits is ONE across signals, route crossings, fault cells and
// routine cells: a name two of them generate would be a duplicate V constant, so cfg2v refuses it.
// Run on examples/overspeed's config (a routine SelfCheck, a fault-owning EngineMonitor), with one
// cross-partition signal added.

const ch_ex = os.join_path(@VMODROOT, 'examples', 'overspeed')

fn cfg2v_with(name string, signal string) os.Result {
	tmp := os.join_path(os.temp_dir(), 'cfg2v_${name}_${os.getpid()}')
	os.mkdir_all(tmp) or { panic(err) }
	defer {
		os.rmdir_all(tmp) or {}
	}
	src := os.read_file(os.join_path(ch_ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, src + '\n[[signal]]\nname = "${signal}"\nfields = { v = "u8" }\nfrom = "sense"\nto   = "ctrl"\n') or {
		panic(err)
	}
	return os.exec([sysmodel.tool_binary('cfg2v') or { panic(err) }, ecu,
		os.join_path(tmp, 'ecu_gen.v')])
}

fn test_a_signal_cannot_take_a_routine_or_fault_channel() {
	for sig, cell in {
		'RoutineReqSelfCheck':   'the request cell of routine "SelfCheck"'
		'RoutineResSelfCheck':   'the result cell of routine "SelfCheck"'
		'FaultRepEngineMonitor': 'the fault report of EngineMonitor'
		'FaultCtlEngineMonitor': 'the fault control of EngineMonitor'
	} {
		r := cfg2v_with(sig, sig)
		assert r.exit_code != 0, '${sig}: accepted\n${r.output}'
		assert r.output.contains('both generate the IOC channel') && r.output.contains(cell), r.output
	}
	ok := cfg2v_with('free', 'RoutineSelfCheckReq')
	assert ok.exit_code == 0, ok.output
}
