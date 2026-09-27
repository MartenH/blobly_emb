module main

import os

// The diagnostic half of a generated bridge pass must run in ONE order, and review found the
// same seam three times running (a pending reset vs. the next request; a request vs. the frames
// queued behind it). This pins the order in the committed generated glue of examples/overspeed —
// which CI's "Generated outputs are fresh" gate keeps identical to what loom2v emits today:
//
//   S3 tick → receive gate sampled → rx drain, stopping at a completed request →
//   pending reset applied → one request taken (never while a response is in flight) →
//   response transmitted → a queued functional request (only on a quiet link, no reset pending)
//   → the 0x28 tx gate sampled → application tx.
fn test_the_generated_diagnostic_pass_runs_in_order() {
	glue := os.read_file(os.join_path(@VMODROOT, 'examples', 'overspeed', 'gen', 'loom_gen.v')) or {
		assert false, '${err}'
		return
	}
	steps := [
		'st.uds_diag.tick(now)',
		'diag_rx_ok :=',
		'if st.tp_diag.has_request() {',
		'st.uds_diag.reset_state()',
		'diag_n := if st.tp_diag.busy() { 0 } else { st.tp_diag.take(',
		'st.tp_diag.poll(now, mut pdu_diag)',
		'st.tp_diag.idle() && st.uds_diag.reset_req == 0',
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
