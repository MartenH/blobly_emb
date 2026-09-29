module main

import os

// The diagnostic half of a generated bridge pass must run in ONE order, and review found the
// same seam three times running (a pending reset vs. the next request; a request vs. the frames
// queued behind it). This pins the order in the committed generated glue of examples/overspeed —
// which CI's "Generated outputs are fresh" gate keeps identical to what loom2v emits today:
//
//   housekeeping (ISO-TP timeouts expired → a pending reset applied → S3 held while the link is
//   busy → S3 checked) → receive gate sampled → rx drain, stopping at a request that completes
//   during it → one request served (one that completes while a response is still in
//   flight is dropped — half-duplex, the tester retries) →
//   response transmitted → the rx gate re-sampled and the rx deadlines checked (after the pass's
//   requests, so a 0x28 suspends them first) → the 0x28 tx gate sampled → application tx. A
//   functional request is served ON ARRIVAL inside the drain (quiet link, no reset pending) and
//   re-samples the rx gate at once.
fn test_the_generated_diagnostic_pass_runs_in_order() {
	glue := os.read_file(os.join_path(@VMODROOT, 'examples', 'overspeed', 'gen', 'loom_gen.v')) or {
		assert false, '${err}'
		return
	}
	// the connection's own steps (housekeeping, one request at a time, the drop while busy) are
	// comm/diag's and tested there; this pins where the bridge calls them
	steps := [
		'st.conn_diag.housekeep(now)',
		'diag_rx_ok :=',
		'match st.conn_diag.on_frame(now, rx) {',
		'.request { break }',
		'.served {',
		'diag_rx_ok = st.conn_diag.server.rx_enabled()',
		'st.conn_diag.serve()',
		'st.conn_diag.produce(now, mut cf_diag)',
		'st.conn_diag.abort_tx()',
		'diag_rx_ok = st.conn_diag.server.rx_enabled()',
		'if diag_rx_ok && st.diag_rx_was_off',
		'diag_tx_ok :=',
		'if tx_lamp_frame_any && diag_tx_ok',
	]
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}
