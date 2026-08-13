module main

import os

// No @verifies: this proves a property of the GENERATOR's output, not a requirement — the
// telemetry requirements (REQ-TELEM-002) are verified by the target tests that read the frame.
//
// Every generated telemetry send is tx_ready-gated (emb#252 defect 3). The trace drain and the
// COM bridge on the same loop can leave the Tx FIFO full for a whole burst; an ungated send()
// there returns false and the CpuLoad/LoadDetail frame is gone with nothing said. The gate is
// part of the CONDITION, not the body, so last_telem stays un-updated and the frame is still due
// on the next pass. This reads the checked-in generated glue rather than the emitter: what ships
// on the target is the artifact, and a run-model added later gets caught here without being
// wired into a test by hand.
fn test_every_generated_telemetry_send_is_tx_ready_gated() {
	root := os.dir(os.dir(os.dir(@FILE)))
	mut checked := 0
	for d in os.ls(os.join_path(root, 'examples')) or { [] } {
		f := os.join_path(root, 'examples', d, 'gen', 'loom_gen.v')
		if !os.exists(f) {
			continue
		}
		for i, line in os.read_lines(f) or { [] } {
			if !line.contains('last_telem >=') {
				continue
			}
			checked++
			assert line.contains('tx_ready()'), '${d}/gen/loom_gen.v:${i + 1} sends telemetry ' +
				'without a tx_ready() gate — a full FIFO drops it silently:\n${line}'
		}
	}
	assert checked > 0, 'found no generated telemetry sends to check — did the gen/ layout move?'
}
