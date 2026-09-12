module main

import os
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
	// BOTH values of with_load. With load telemetry on, load accounting independently forces the
	// t0/t1 bracket and the io_exec_add call, so this assertion cannot tell whether the trace-only
	// (excl) path still publishes the sum. A [trace] level="all" io image with telemetry disabled
	// is a supported shape, and the hardware fixture has telemetry ENABLED — so that regression
	// would have been invisible from every direction (codex on #280).
	for with_load in [true, false] {
		check_whole_pass_bracket(with_load)
	}
}

fn check_whole_pass_bracket(with_load bool) {
	m := traced_io_model()
	g := emit_io_target_entry(m, empty_doc(), {
		'Fast': 0
		'Slow': 1
	}, with_load, 0).join('\n')
	lines := g.split('\n')
	mut i_t0 := -1
	mut i_t1 := -1
	mut i_add := -1
	mut n_add := 0
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
			n_add++
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
	assert i_t0 >= 0 && i_t1 >= 0 && i_add >= 0, 'with_load=${with_load}: the pass bracket or the exec publish is missing'
	// EXACTLY one. Two publications double the sum, so the FB threads over-subtract io preemption
	// — and the bench test's wall-clock ceiling admits it easily, since io execution is a tiny
	// fraction of the window (codex on #280).
	assert n_add == 1, 'with_load=${with_load}: the whole pass is published ${n_add} times — g_io_exec_us would be inflated and FB preemption over-subtracted'
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
	// 2) every advertised id is one the LOOP actually records — EXACTLY ONCE. Containment alone
	//    would accept a duplicated call, and REQ-IO-025 is one record per point SERVICED: two
	//    would corrupt every count a dump derives, while the hardware check (NREC > 0) and the
	//    containment check both still passed (codex on #280).
	for i, id in io_ids {
		n := loop.count('C.trace_fb(u32(${id}),')
		assert n == 1, 'the emitted loop records id ${id} ("${io_names[i]}") ${n} times — REQ-IO-025 is one record per point serviced'
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
	// 5) and each point's record follows ITS OWN OPERATION. The whole-pass test anchors on the
	//    record as the point's completion; that anchor is only sound if the record actually comes
	//    after the work. Emitted before it, every ordering assertion would still pass while the
	//    recorded duration measured the clock call and not the service (codex on #280).
	lines := loop.split('\n')
	for i, pt in m.io_points {
		op := match pt.kind {
			'pwm' { 'io.pwm_write(' }
			'adc' { 'io.adc_read_checked(' }
			else { if pt.output { 'io.gpio_write(' } else { 'io.gpio_read_checked(' } }
		}
		hid := base + u32(i)
		// Search THIS POINT'S BRACKET only — from its own p<hid>_t0 to its own record. A bare
		// first-match on the primitive is wrong the moment two points share one: with three GPIO
		// points (examples/h755_io has exactly that) the match would stay on the FIRST gpio call,
		// so a later point's record could precede its own operation and still look ordered. The
		// one-gpio/one-adc fixture masked that (codex on #280).
		mut i_start := -1
		mut i_rec := -1
		for k, l in lines {
			if l.contains('p${hid}_t0 := C.board_now_us()') {
				i_start = k
			}
			if l.contains('C.trace_fb(u32(${hid}),') {
				i_rec = k
			}
		}
		assert i_start >= 0, 'no per-point bracket start for "${pt.name}" (id ${hid})'
		assert i_rec > i_start, 'point "${pt.name}": its record precedes its own bracket start'
		mut i_op := -1
		for k := i_start; k < i_rec; k++ {
			if lines[k].contains(op) {
				i_op = k
				break
			}
		}
		assert i_op > i_start, 'point "${pt.name}" (${pt.kind}): no ${op} between its bracket start and its record — the duration would exclude the service'
	}
}

// THE C SIDE (covered by this file's verification tag at the top — a SECOND tag would register a
// second link and list the file twice in the requirement's evidence, which is the duplicate this
// file already had to fix once). Everything above asserts what the GENERATOR emits, and the emitted call is
// `C.io_exec_add(u32(t1 - t0))` — what it lands on is a one-line accumulator in each board glue.
// A copy that ignored its argument and added a constant would leave the generated code perfect,
// the silicon check still seeing the counter advance inside its ceiling, and the whole-pass claim
// false. That was the residual the bench test documented rather than covered (codex on #280).
//
// The glue is not host-compilable (tx_api.h, stm32h7xx.h), so this asserts its TEXT — the same
// thing scripts/lint_vinit.sh does for an invariant the host cannot execute. Narrow on purpose:
// that the accumulator ADDS ITS PARAMETER, which is precisely the regression invisible from every
// other direction.
fn test_every_io_exec_accumulator_adds_its_argument() {
	mut found := 0
	for root in ['boards', 'examples'] {
		for f in os.walk_ext(os.join_path(@VMODROOT, root), '.c') {
			// AUTHORED glue only. build/ holds V-generated C, which today carries calls and no
			// definition — but scanning generated output for a source invariant is the wrong
			// shape regardless, and a prototype appearing there later would trip the body check
			// below and fail `make trace` purely because someone had built an example first.
			if f.contains('/build/') {
				continue
			}
			found += check_accumulator(f)
		}
	}
	assert found >= 6, 'found ${found} io_exec_add definitions, expected at least the 6 board glue copies — did the search path or the file layout change?'
}

fn check_accumulator(path string) int {
	src := os.read_file(path) or { return 0 }
	mut n := 0
	for line in src.split_into_lines() {
		if !line.contains('void io_exec_add(') {
			continue
		}
		// a DEFINITION, not a prototype: the body has to be on this line for the check below to
		// mean anything, and a declaration carries no body to judge
		if !line.contains('{') || !line.contains('}') {
			continue
		}
		n++
		param := line.all_after('(').all_before(')').trim_space().all_after_last(' ')
		assert param != '', '${path}: cannot read the parameter name from: ${line}'
		// `+= <param>`, as a PATTERN. A bare `body.contains(param)` is useless here: the parameter
		// is `us` and the accumulator it writes to is `g_io_exec_us`, so the substring matches even
		// when the body ignores the argument entirely — `g_io_exec_us += 1;` passed that check.
		body := line.all_after('{')
		assert body.contains('+= ${param}'), '${path}: io_exec_add does not accumulate its argument (want "+= ${param}"): ${line.trim_space()}'
		// ...and the GETTER must return that same variable. The generated FB loops consume
		// C.io_exec_us() to subtract io preemption, so a getter returning 0 or a different global
		// stops the subtraction while every other check here stays green — and the bench script
		// reads g_io_exec_us straight out of the ELF, bypassing the accessor entirely
		// (codex on #280).
		acc := body.all_before('+=').trim_space()
		assert acc != '', '${path}: cannot read the accumulated variable from: ${line.trim_space()}'
		mut saw_getter := false
		for gl in src.split_into_lines() {
			if !gl.contains('io_exec_us(void)') {
				continue
			}
			saw_getter = true
			gbody := gl.all_after('{')
			assert gbody.contains(acc), '${path}: io_exec_us() does not return ${acc}, the variable io_exec_add updates — the FB loops would stop subtracting io preemption: ${gl.trim_space()}'
		}
		assert saw_getter, '${path}: io_exec_add is defined with no io_exec_us() accessor beside it — the FB loops read the sum through that getter'
	}
	return n
}
