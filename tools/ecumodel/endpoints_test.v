module ecumodel

import toml

// @verifies REQ-INV-007
// A signal's endpoints, as written or derived from the FBs (endpoints.v): what is derived, the one
// reader pick, and each refusal — a stale endpoint is refused naming both sides.

const parts = '[[partition]]\nname = "ctl"\ncore = 0\n  [[partition.thread]]\n  name = "fast"\n' +
	'[[partition]]\nname = "aux"\ncore = 0\n  [[partition.thread]]\n  name = "slow"\n' +
	'[[partition]]\nname = "sat"\ncore = 1\nimage = "nodes/sat"\n  [[partition.thread]]\n  name = "model"\n'

fn fb_toml(name string, thr string, reads []string, writes []string) string {
	rs := reads.map('"${it}"').join(', ')
	ws := writes.map('"${it}"').join(', ')
	return '[[fb]]\nname = "${name}"\nthread = "${thr}"\n  [[fb.handler]]\n  name = "on_10ms"\n  period_ms = 10\n  reads = [${rs}]\n  writes = [${ws}] # ends the nested table (vlang/v#27684)\n'
}

fn sig_toml(name string, ends string) string {
	return '[[signal]]\nname = "${name}"\nfields = { v = "u32" }\n${ends}'
}

fn endpoints_of(src string) (map[string]SigEnds, []string) {
	doc := toml.parse_text(src) or { panic(err) }
	return signal_endpoints(doc)
}

fn test_left_out_endpoints_follow_the_writer_and_the_readers() {
	ends, errs := endpoints_of(parts + sig_toml('X', '') + fb_toml('W', 'fast', [], ['X']) +
		fb_toml('R', 'model', ['X'], []))
	assert errs == []
	assert ends['X'].from == 'ctl' && ends['X'].from_derived
	assert ends['X'].to == 'sat' && ends['X'].to_derived
}

fn test_the_reader_pick_prefers_the_owner_image_and_another_partition() {
	own := {
		'sat': true
	}
	// a satellite reader loses to an owner-image one
	assert consumer_partition('', ['sat', 'ctl'], own) == 'ctl'
	// a same-image reader elsewhere keeps its channel: not the writer's own partition
	assert consumer_partition('ctl', ['ctl', 'aux'], own) == 'aux'
	// read only where it is written: local
	assert consumer_partition('ctl', ['ctl', 'sat'], own) == 'ctl'
	assert consumer_partition('ctl', [], own) == ''
}

fn test_unread_and_unwritten_signals_are_settled_or_refused() {
	// written, read nowhere yet: local to its writer
	ends, errs := endpoints_of(parts + sig_toml('X', '') + fb_toml('W', 'fast', [], ['X']))
	assert errs == []
	assert ends['X'].to == 'ctl'
	// a received signal no FB reads cannot derive its consumer — never a bus -> bus signal
	_, errs2 := endpoints_of(parts + sig_toml('Rx', 'from = "can0"\n'))
	assert errs2.any(it.contains('signal "Rx" leaves out `to` and no fb reads it'))
	// no writer, `from` left out: refused once, the written `to` kept
	ends3, errs3 := endpoints_of(parts + sig_toml('Y', 'to = "io"\n'))
	assert errs3.len == 1 && errs3[0].contains('signal "Y" leaves out `from` and no fb writes it')
	assert ends3['Y'].to == 'io' && ends3['Y'].from == ''
}

fn test_two_writing_partitions_are_refused() {
	_, errs := endpoints_of(parts + sig_toml('X', '') + fb_toml('A', 'fast', [], ['X']) +
		fb_toml('B', 'model', [], ['X']))
	assert errs.any(it.contains('signal "X" is written in 2 partitions (ctl, sat)'))
}

fn test_a_written_endpoint_is_checked_against_the_fbs() {
	_, errs := endpoints_of(parts + sig_toml('X', 'from = "sat"\nto = "ctl"\n') +
		fb_toml('W', 'fast', [], ['X']) + fb_toml('R', 'model', ['X'], []))
	assert errs.any(it.contains('signal "X" declares from = "sat", but fb "W" writes it in partition "ctl"'))
	assert errs.any(it.contains('signal "X" declares to = "ctl", but no fb in partition "ctl" reads it (fb "R" reads it in "sat")'))
	// a thread name stands for its partition
	_, ok := endpoints_of(parts + sig_toml('X', 'from = "fast"\nto = "model"\n') +
		fb_toml('W', 'fast', [], ['X']) + fb_toml('R', 'model', ['X'], []))
	assert ok == []
	// a `to` no FB reads (platform C reads it) stays the author's word
	_, plat := endpoints_of(parts + sig_toml('X', 'from = "sat"\nto = "ctl"\n') +
		fb_toml('W', 'model', [], ['X']))
	assert plat == []
}
