module main

import toml

// IO point trace records (#263, REQ-IO-025). Their ids continue the GLOBAL handler numbering, so
// a point's records can never be read as some FB handler's — and emit_manifest writes its rows in
// the same order, one per point, which is what a dump resolves them through. The id is computed
// in two places; these pin them together, and exercise the emitted loop itself.

fn empty_doc() toml.Doc {
	return toml.parse_text('') or { panic(err) }
}

// handler_id_base walks the partitions AS DECLARED, so the counting tests need a doc that
// declares one; the emission tests below want no FB handlers at all, and use empty_doc().
fn app_doc() toml.Doc {
	return toml.parse_text('[[partition]]
name = "app"
core = 0
') or { panic(err) }
}

fn two_fbs_two_handlers() Model {
	mut m := Model{}
	m.part.by_part['app'] = [
		toml.Any({
			'name':    toml.Any('A')
			'handler': toml.Any([toml.Any('x'), toml.Any('y')])
		}),
		toml.Any({
			'name':    toml.Any('B')
			'handler': toml.Any([toml.Any('x'), toml.Any('y')])
		}),
	]
	return m
}

fn test_io_ids_start_past_every_fb_handler() {
	// four handlers -> global ids 0..3, so the io points start at 4
	m := two_fbs_two_handlers()
	assert io_handler_id_base(m, app_doc()) == 4, 'got ${io_handler_id_base(m, app_doc())}'
}

fn test_io_ids_start_at_zero_when_no_fb_handlers_exist() {
	// an io-only node (docs/io.md: an output-only ECU) has no FB handlers at all
	assert io_handler_id_base(Model{}, app_doc()) == 0
}

fn traced_io_model() Model {
	mut m := Model{}
	m.trace.on = true
	m.trace.level = 'all'
	m.io_points = [
		IoPoint{
			name:      'Fast'
			kind:      'gpio'
			period_ms: 10
			ch:        0
		},
		IoPoint{
			name:      'Slow'
			kind:      'adc'
			period_ms: 100
			ch:        1
		},
	]
	return m
}

fn test_each_point_is_bracketed_and_recorded() {
	m := traced_io_model()
	g := emit_io_target_entry(m, empty_doc(), {
		'Fast': 0
		'Slow': 1
	}, false, 0).join('\n')
	// one bracket + one record per point, ids 0 and 1 (this node has no FB handlers)
	assert g.contains('p0_t0 := C.board_now_us()')
	assert g.contains('C.trace_fb(u32(0), p0_t0,')
	assert g.contains('p1_t0 := C.board_now_us()')
	assert g.contains('C.trace_fb(u32(1), p1_t0,')
	// the sub-rated point's bracket belongs INSIDE its own gate, not the base tick's
	gate := g.index('if (tick + 1) % 10 == 0') or { panic('the 100 ms point lost its gate') }
	assert g.index('p1_t0 := ') or { 0 } > gate
}

fn test_no_records_below_level_all() {
	// "thread+fb" traces the FB lanes; per-point io records are the level="all" addition, and
	// the thread-level exec sum the FB threads subtract is emitted either way.
	mut m := traced_io_model()
	m.trace.level = 'thread+fb'
	g := emit_io_target_entry(m, empty_doc(), {
		'Fast': 0
		'Slow': 1
	}, true, 0).join('\n')
	assert !g.contains('C.trace_fb(')
	assert g.contains('C.io_exec_add('), 'the preemption sum is not conditional on the level'
}

// A point with no IOC cell is skipped in the LOOP but still gets a manifest row, so ids must come
// from the point's index — a running counter would shift every later point onto the wrong row.
fn test_a_skipped_point_does_not_shift_the_others() {
	m := traced_io_model()
	g := emit_io_target_entry(m, empty_doc(), {
		'Slow': 1
	}, false, 0).join('\n') // 'Fast' has no cell
	assert !g.contains('trace_fb(u32(0)')
	assert g.contains('C.trace_fb(u32(1), p1_t0,'), 'the surviving point took the skipped id'
}
