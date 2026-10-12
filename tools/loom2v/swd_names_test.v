module main

import os

// Every generated global read by name over SWD keeps that name in C: declared on its own line
// under `@[export]`, never inside a `__global (` block, where V3 would call it `gen__<name>`.
// Checked over every committed example output, which the freshness gate holds to the generator.
fn test_swd_globals_keep_their_names() {
	mut seen := map[string]bool{}
	for f in os.walk_ext(os.join_path(@VMODROOT, 'examples'), '.v') {
		if os.file_name(f) != 'loom_gen.v' {
			continue
		}
		lines := os.read_lines(f) or { panic(err) }
		mut in_block := false
		for i, l in lines {
			t := l.trim_space()
			if t == '__global (' {
				in_block = true
				continue
			}
			if in_block && t == ')' {
				in_block = false
				continue
			}
			for name in swd_names {
				if in_block && (t == name || t.starts_with('${name} ')) {
					assert false, '${f}:${i + 1}: ${name} is declared inside a __global block'
				}
				if t.starts_with('__global ${name} ') {
					assert i > 0 && lines[i - 1].trim_space() == "@[export: '${name}']", '${f}:${i + 1}: ${name} without its export'
					seen[name] = true
				}
			}
		}
	}
	// the committed examples carry the ring, the io counter and the comm thread's counters
	for name in ['g_trace_ring', 'io_startup_faults', 'g_rx_count', 'g_rx_last'] {
		assert seen[name], '${name} is declared by no committed example'
	}
}
