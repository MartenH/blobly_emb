module main

import os

// The diagnostic half of a generated bridge pass must run in ONE order, and review found the
// same seam three times running (a pending reset vs. the next request; a request vs. the frames
// queued behind it). This pins the order in the committed generated glue of examples/overspeed —
// which CI's "Generated outputs are fresh" gate keeps identical to what loom2v emits today:
//
//   S3 tick → receive gate sampled → rx drain, stopping at a request that completes during it →
//   pending reset applied → one request served (one that completes while a response is still in
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
	steps := [
		'st.uds_diag.tick(now)',
		'diag_rx_ok :=',
		'if st.tp_diag.has_request() {',
		'st.tp_diag.idle() && st.uds_diag.reset_req == 0 {',
		'st.uds_diag.reset_state()',
		'diag_got := st.tp_diag.take(',
		'diag_n := if st.tp_diag.busy() { 0 } else { diag_got }',
		'st.tp_diag.poll(now, mut pdu_diag)',
		'st.uds_diag.hold_s3()',
		'diag_rx_ok = st.uds_diag.rx_enabled()\n\tif diag_rx_ok && st.diag_rx_was_off',
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
