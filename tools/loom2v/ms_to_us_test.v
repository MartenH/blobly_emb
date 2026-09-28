module main

// Authored timeouts are bounded in ms BEFORE the µs multiply, so no value — not even one near
// max_i64 — can wrap into a small or negative timeout that silently disables a monitor.
fn test_ms_to_us_bounds() {
	assert ms_to_us(0, 'x') == 0
	assert ms_to_us(300, 'x') == 300_000
	assert ms_to_us(i64(max_i32) / 1000, 'x') == int((i64(max_i32) / 1000) * 1000)
}
