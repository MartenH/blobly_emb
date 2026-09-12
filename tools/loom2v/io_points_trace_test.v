module main

import toml

// @verifies REQ-IO-025
//
// The tag above matters, and its absence was not cosmetic: tools/trace/gen.v skips a V test file
// carrying no verification tag before recording it, so this file's evidence was never counted and
// REQ-IO-025 could be marked verified by the silicon check ALONE — which, on a one-point node,
// cannot tell a whole-pass sum from the last point's duration. That discrimination is here.
//
// This prose deliberately says "verification tag" rather than spelling the marker: the scanner
// treats ANY line containing it as metadata, so an explanatory mention registers a second,
// phantom link and the requirement's evidence list showed this file twice (codex on #280).
//
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

// The thread-level sum must bracket the WHOLE PASS, not a point. REQ-IO-025 is two claims: each
// point gets its own record, AND g_io_exec_us still publishes the whole-pass execution the FB
// threads subtract as preemption. On silicon the second claim is only observable as "the counter
// advances" — a regression to adding a constant, or only the last point's duration, would still
// advance and still pass. With ONE io point (system_full's domain) the two are numerically
// indistinguishable on hardware, so the discrimination belongs HERE, in the emitted shape:
// t0 is taken before the first point, t1 after the last, and io_exec_add gets exactly t1 - t0
// (codex on #280).
fn test_the_exec_sum_brackets_the_whole_pass_not_a_point() {
	m := traced_io_model()
	g := emit_io_target_entry(m, empty_doc(), {
		'Fast': 0
		'Slow': 1
	}, true, 0).join('\n')
	lines := g.split('\n')
	mut i_t0 := -1
	mut i_t1 := -1
	mut i_add := -1
	mut first_point := -1
	mut last_point := -1
	for i, l in lines {
		if l.contains('t0 := C.board_now_us()') && i_t0 < 0 {
			i_t0 = i
		}
		if l.contains('t1 := C.board_now_us()') {
			i_t1 = i
		}
		if l.contains('C.io_exec_add(') {
			i_add = i
		}
		// a per-point bracket is p<id>_t0; the pass bracket is the bare t0
		if l.contains('_t0 := C.board_now_us()') {
			if first_point < 0 {
				first_point = i
			}
		}
		// ...and the point's COMPLETION is its record, emitted after its io operation. Anchoring
		// on the start marker was not enough: t1 could sit between the last point's p_t0 and its
		// actual work, and both this and the t1 - t0 assertion would still pass while the
		// aggregate excluded that point's service time (codex on #280).
		if l.contains('C.trace_fb(') {
			last_point = i
		}
	}
	assert i_t0 >= 0 && i_t1 >= 0 && i_add >= 0, 'the pass bracket or the exec publish is missing'
	assert first_point > 0, 'expected a per-point bracket in the fixture'
	assert last_point > first_point, 'expected a per-point RECORD after the first bracket in the fixture'
	assert i_t0 < first_point, 'the exec sum starts AFTER the first point — it would miss that point'
	assert i_t1 > last_point, 'the exec sum ends BEFORE the last point\'s record — it would miss that point\'s service time'
	// and it publishes the bracket itself, not a point's duration or a constant
	assert lines[i_add].contains('u32(t1 - t0)'), 'io_exec_add does not publish t1 - t0: ${lines[i_add]}'
}

// BOTH SIDES OF THE MAPPING. The bench test reads gen/trace-manifest.csv as its oracle — it can
// only ask "does the ring hold records for the ids the manifest advertises". So a manifest that
// emitted a wrong id, or swapped two rows, would be believed: io points and FB handlers share
// kind=FB, so an id colliding with a handler could even make the silicon check pass against that
// handler's records while a dump resolved the wrong configured name. Nothing compared the two
// emitters until now — the loop test exercises the loop, and never called emit_manifest
// (codex on #280).
fn test_the_manifest_rows_and_the_emitted_records_agree() {
	// WITH FB handlers, deliberately: the collision assertion below is dead without them, which
	// is how my first version of this test passed a perturbation that set the io ids to 0,1 —
	// an empty-handler fixture has nothing for them to collide WITH.
	mut m := two_fbs_two_handlers()
	m.trace.on = true
	m.trace.level = 'all'
	m.io_points = traced_io_model().io_points
	doc := app_doc()
	rows := emit_manifest(m, doc, 'ecu.toml', false, '', [])
	loop := emit_io_target_entry(m, doc, {
		'Fast': 0
		'Slow': 1
	}, true, 0).join('\n')

	// the io rows, in order: <id>,io,<core>,io,<name>,<period_us>,io
	mut io_ids := []string{}
	mut io_names := []string{}
	mut handler_ids := []string{}
	for r in rows {
		f := r.split(',')
		if f.len < 7 || r.starts_with('#') {
			continue
		}
		if f[1] == 'io' && f[3] == 'io' {
			io_ids << f[0]
			io_names << f[4]
		} else if f[0].len > 0 && f[0][0].is_digit() {
			handler_ids << f[0] // an fb.handler row: id,partition,core,fb,handler,period,thread
		}
	}
	assert io_ids.len == m.io_points.len, 'manifest has ${io_ids.len} io rows for ${m.io_points.len} points'

	// 1) the NAMES are the configured points, in the configured order — a swap is a wrong name
	for i, pt in m.io_points {
		assert io_names[i] == pt.name, 'manifest io row ${i} names "${io_names[i]}", configured point is "${pt.name}"'
	}
	// 2) every advertised id is one the LOOP actually records, so the oracle cannot point at an id
	//    nothing emits (which is what the bench test would then look for in the ring)
	for i, id in io_ids {
		assert loop.contains('C.trace_fb(u32(${id}),'), 'manifest advertises id ${id} for "${io_names[i]}" but the emitted loop records no such id'
	}
	// 3) and no io id collides with an FB HANDLER id — they share kind=FB in the ring, so a
	//    collision makes the two indistinguishable to any decoder
	for id in io_ids {
		assert id !in handler_ids, 'io point id ${id} collides with an fb.handler id — both are kind=FB in the ring'
	}
	// 4) the ids are contiguous from the base, so a point is not silently skipped in the manifest
	base := io_handler_id_base(m, doc)
	for i, id in io_ids {
		assert id == (base + u32(i)).str(), 'manifest io row ${i} has id ${id}, expected ${base + u32(i)}'
	}
}
