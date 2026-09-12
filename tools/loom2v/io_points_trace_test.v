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

// stmt_of: an emitted line reduced to its statement — indentation and any trailing `// comment`
// removed — so a test can compare the WHOLE call instead of a prefix. Prefix matching is how this
// file was wrong four times: `+= us` admitted `+= us + 1`, `contains(acc)` admitted a shadowed
// global, and `C.io_exec_add(` / `C.trace_fb(u32(id),` admit any argument list at all.
fn stmt_of(line string) string {
	mut t := line.trim_space()
	if t.contains('//') {
		t = t.all_before('//').trim_space()
	}
	return t
}

fn check_whole_pass_bracket(with_load bool) {
	m := traced_io_model()
	g := emit_io_target_entry(m, empty_doc(), {
		'Fast': 0
		'Slow': 1
	}, with_load, 0).join('\n')
	lines := strip_comments(g)
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
	// The COMPLETE call: `C.io_exec_add(u32(t1 - t0) + 1)` contains `u32(t1 - t0)` and would have
	// passed, inflating every pass while the C-side check faithfully accumulated the inflated
	// argument and the silicon ceiling admitted it (codex on #280).
	got_add := stmt_of(lines[i_add])
	assert got_add == 'C.io_exec_add(u32(t1 - t0))', 'with_load=${with_load}: the whole pass is published as `${got_add}`, not exactly `C.io_exec_add(u32(t1 - t0))` — anything else is not the pass duration'
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
	lines := strip_comments(loop)
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
		// ...and the record's DURATION must come from this point's own bracket. Matching the
		// `C.trace_fb(u32(<hid>),` prefix accepts any third argument, so a constant or the
		// whole-pass elapsed time would satisfy every other check here.
		//
		// This assertion is the ONLY evidence for that. The hardware test observes record
		// PRESENCE and reports whatever duration it finds — it does not, and cannot, judge the
		// expression the value came from: a value is just a value on the wire, and a legitimate
		// sub-microsecond service reads 0us, so no observed number distinguishes a real bracket
		// from a fabricated one. (The rationale here said "the hardware test requires a nonzero
		// duration" for a round after that requirement was dropped — describing the sibling
		// check's assertions is how these comments keep going stale; describe what this one
		// establishes instead.)
		// UNCONDITIONAL within the point's service. stmt_of discards indentation, so moving this
		// exact call inside the existing `if C.ioc_get_ever(...)` publish gate satisfied the text
		// and the ordering while an output whose producer has never published is serviced at every
		// cadence and records NOTHING — and the HostLed fixture eventually publishes, so silicon
		// would not show it either (codex on #280). The record must sit at the same indent as the
		// point's own bracket start.
		ind_start := lines[i_start].len - lines[i_start].trim_left(' \t').len
		ind_rec := lines[i_rec].len - lines[i_rec].trim_left(' \t').len
		assert ind_rec == ind_start, 'point "${pt.name}": its record is indented ${ind_rec} against a bracket at ${ind_start} — it sits inside a conditional, so a service that does not take that branch records nothing'
		want := 'C.trace_fb(u32(${hid}), p${hid}_t0, u32(C.board_now_us() - p${hid}_t0))'
		got_rec := stmt_of(lines[i_rec])
		assert got_rec == want, 'point "${pt.name}": record is `${got_rec}`, want `${want}` — the duration must be this point\'s own measured interval'
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

// strip_comments returns `src`'s lines with all comment text removed and the LINE COUNT preserved,
// so index comparisons in the ordering tests stay valid. It tracks `/* ... */` across lines, which
// per-line stripping cannot: a call disabled inside a normal multiline block comment was still
// captured as executable code, and every assertion about it then passed while the compiled function
// did nothing (codex on #280).
//
// This replaced a per-line code_of() that handled `//` and same-line `/* */` only — three rounds of
// findings walked that from "no stripping" to "// only" to "same-line block" to here. State is the
// thing a per-line view cannot have, so the per-line version could never have been finished.
fn strip_comments(src string) []string {
	mut out := []string{}
	mut in_block := false
	for line in src.split_into_lines() {
		mut kept := ''
		mut i := 0
		for i < line.len {
			if in_block {
				if i + 1 < line.len && line[i] == `*` && line[i + 1] == `/` {
					in_block = false
					i += 2
					continue
				}
				i++
				continue
			}
			if i + 1 < line.len && line[i] == `/` && line[i + 1] == `*` {
				in_block = true
				i += 2
				continue
			}
			if i + 1 < line.len && line[i] == `/` && line[i + 1] == `/` {
				break // line comment: the rest is not code
			}
			kept += line[i].ascii_str()
			i++
		}
		out << kept
	}
	return out
}

// squeeze_call removes any whitespace between `name` and the `(` that follows it, so a scan can
// key on the IDENTIFIER rather than on one spelling of the call. `name  (x)` and `name\t(x)` are
// valid C; three successive versions of the scan below assumed otherwise and silently skipped a
// definition each time.
fn squeeze_call(line string, name string) string {
	i := line.index(name) or { return line }
	mut j := i + name.len
	for j < line.len && (line[j] == ` ` || line[j] == `\t`) {
		j++
	}
	if j >= line.len || line[j] != `(` {
		return line // not a call or definition of `name` at all
	}
	return line[..i + name.len] + line[j..]
}

fn check_accumulator(path string) int {
	src := os.read_file(path) or { return 0 }
	mut n := 0
	for line in strip_comments(src) {
		// Discovery is on the IDENTIFIER, not on `void io_exec_add(`. Requiring the return type on
		// the same line is a FORMATTING assumption: a backend writing `void` on its own line was
		// skipped silently, and `found >= 6` stayed satisfied by the other copies while that one
		// went unchecked (codex on #280). Every occurrence is now classified, and anything this
		// scanner cannot classify FAILS rather than being passed over.
		// Identifier, then ARBITRARY whitespace, then `(`. Three spellings of one mistake got here:
		// requiring `void` on the same line, then requiring no space before the paren, then
		// normalising exactly one `" ("` — so `io_exec_add  (` and a tab still slipped past while
		// `found >= 6` stayed satisfied by the other copies (codex on #280). squeeze_call() is the
		// last version of this: it answers for any C spacing.
		if !line.contains('io_exec_add') {
			continue
		}
		t := squeeze_call(line.trim_space(), 'io_exec_add')
		// The identifier is here but this scan cannot see its `(` on this line: a multiline
		// signature (`void io_exec_add` then `(unsigned us)`) was SKIPPED, and with six one-line
		// copies keeping `found >= 6` a seventh backend could accumulate the wrong value and stay
		// invisible. An occurrence that cannot be parsed fails instead (codex on #280).
		assert t.contains('io_exec_add('), '${path}: io_exec_add appears in a form this scan cannot read — the identifier and its `(` must be on one line so the accumulation can be checked, or this scan silently stops covering that backend: ${line.trim_space()}'
		// a CALL or a PROTOTYPE: statement-terminated, no body. Neither is a definition to judge.
		if t.ends_with(';') && !t.contains('{') {
			continue
		}
		n++
		assert t.contains('{') && t.contains('}'), '${path}: io_exec_add appears in a form this scan cannot read on one line — a definition must be `{ <acc> += <param>; }` so the accumulation can be checked, or the scan silently stops covering that backend: ${t}'
		param := t.all_after('(').all_before(')').trim_space().all_after_last(' ')
		assert param != '', '${path}: cannot read the parameter name from: ${t}'
		// `+= <param>`, as a PATTERN. A bare `body.contains(param)` is useless here: the parameter
		// is `us` and the accumulator it writes to is `g_io_exec_us`, so the substring matches even
		// when the body ignores the argument entirely — `g_io_exec_us += 1;` passed that check.
		// The WHOLE update expression, not a prefix: `+= us` also matches `+= us + 1`, which
		// inflates every pass while the counter still advances under its ceiling. Same class as
		// the earlier `contains(param)` bug, where the parameter `us` matched the global
		// `g_io_exec_us` (codex on #280, twice on this one check).
		stmt := t.all_after('{').all_before('}').trim_space().trim_right(';').trim_space()
		parts := stmt.split('+=')
		assert parts.len == 2, '${path}: io_exec_add body is not a single `X += ${param};` accumulation: ${line.trim_space()}'
		acc := parts[0].trim_space()
		rhs := parts[1].trim_space()
		assert rhs == param, '${path}: io_exec_add accumulates "${rhs}", not exactly its argument "${param}" — anything else publishes a value that is not the pass duration: ${line.trim_space()}'
		// ...and the GETTER must return that same variable. The generated FB loops consume
		// C.io_exec_us() to subtract io preemption, so a getter returning 0 or a different global
		// stops the subtraction while every other check here stays green — and the bench script
		// reads g_io_exec_us straight out of the ELF, bypassing the accessor entirely
		// (codex on #280).
		assert acc != '', '${path}: cannot read the accumulated variable from: ${line.trim_space()}'
		mut saw_getter := false
		for gl in src.split_into_lines() {
			gt := squeeze_call(gl.trim_space(), 'io_exec_us')
			if !gt.contains('io_exec_us(void)') {
				continue
			}
			// a forward declaration carries no body to read: skip it, as the adder scan does,
			// rather than trying to extract a return expression from absent braces and failing
			// the whole run while the real definition below is correct (codex on #280).
			if gt.ends_with(';') && !gt.contains('{') {
				continue
			}
			saw_getter = true
			// EXACTLY the accumulator, not a name containing it: `return g_io_exec_us_shadow;`
			// contains `g_io_exec_us` and would have passed (codex on #280).
			ret := gt.all_after('{').all_before('}').trim_space().trim_string_left('return').trim_space().trim_right(';').trim_space()
			assert ret == acc, '${path}: io_exec_us() returns "${ret}", not the "${acc}" that io_exec_add updates — the FB loops would subtract the wrong value: ${gl.trim_space()}'
		}
		assert saw_getter, '${path}: io_exec_add is defined with no io_exec_us() accessor beside it — the FB loops read the sum through that getter'
	}
	return n
}

// The RECORDER side of the duration. The caller assertion above pins the emitted
// `C.trace_fb(u32(<hid>), p<hid>_t0, u32(C.board_now_us() - p<hid>_t0))`, but nothing there can see
// what boards/common/trace_hooks.c then does with that third argument: a push_rec that wrote a
// constant would leave the call site perfect, and the silicon script accepts an all-zero record set
// as valid (a sub-microsecond service reads 0us), so the ring could carry no measured duration at
// all with every other check green (codex on #280).
//
// Text again, for the same reason as the accumulator scan: the file needs tx_api.h and a device
// header, so the host cannot execute it.
// THE RECORDER, PINNED WHOLE. trace_fb and push_rec's record write are compared against their
// exact expected code, comment-free and whitespace-normalised — not probed property by property.
//
// This replaced ten rounds of per-line assertions, each answering one more way that matching text
// differs from meaning: substring vs exact, unscoped vs body-scoped, comments-as-code, first-match
// vs all-matches, nested-under-a-conditional, a preceding early exit, a later reassignment, a
// guard whose condition changed. Every fix was right and every one invited the next, because a text
// scan cannot decide semantics and there is always one more shape (codex on #280, rounds 20-31).
//
// A whole-body comparison is terminal instead: ANY deviation fails, so there is no looser question
// left to ask. The cost is that a legitimate edit to these functions fails this test — which is the
// intent. trace_hooks.c is not host-compilable (tx_api.h, a device header), so nothing here can
// execute it; changing what it records is a decision that should be made deliberately, with the
// expected text updated in the same commit.
fn test_the_recorder_records_exactly_what_it_is_given() {
	path := os.join_path(@VMODROOT, 'boards', 'common', 'trace_hooks.c')
	src := os.read_file(path) or {
		assert false, 'cannot read ${path}: ${err}'
		return
	}
	lines := strip_comments(src)

	want_fb := [
		'unsigned pm;',
		'__asm volatile("mrs %0, primask" : "=r"(pm));',
		'__asm volatile("cpsid i" ::: "memory");',
		'push_rec(KIND_FB, id, 0u, (unsigned long)start_us, dur_us > 0xFFFFu ? 0xFFFFu : dur_us);',
		'__asm volatile("msr primask, %0" :: "r"(pm) : "memory");',
	]
	got_fb := body_of(lines, 'void trace_fb(')
	assert got_fb == want_fb, 'trace_fb\'s body changed.\n got: ${got_fb}\nwant: ${want_fb}\nIt must forward the point id, the start and the SATURATED measured duration to push_rec, on every call, with no early exit and nothing between. If this change is intended, update want_fb in the same commit — the point of pinning it is that what the ring records cannot drift silently (REQ-IO-025).'

	// push_rec: the record write, from the eid through the duration bytes. The PRIMASK/asm framing
	// around it is the ISR-race guard, not part of what is recorded, so it is not pinned here.
	// push_rec: the WHOLE body, not a slice. Pinning only the eid-through-duration region ignored
	// executable statements before and after it — `id = 2u;` ahead of the initialiser, or
	// `r[6] = 0;` after `g_head++` — leaving the slice and the guard assertions unchanged while the
	// record was wrong. "Whole" has to mean whole, or it is first-match looseness in a larger
	// costume (codex on #280). The only early exit, and its condition, are pinned with everything
	// else: a guard changed to `if (dur_us == 0)` drops every sub-microsecond record.
	want_write := [
		'if (!g_capturing)',
		'return;',
		'unsigned prim;',
		'__asm__ volatile("mrs %0, primask; cpsid i" : "=r"(prim) : : "memory");',
		'unsigned eid = ((kind & 0x3u) << 14) | (id & 0x3FFFu);',
		'unsigned char *r = g_ring[g_head & (RING_CAP - 1u)];',
		'r[0] = (unsigned char)(eid & 0xFF);',
		'r[1] = (unsigned char)((eid >> 8) & 0xFF);',
		'r[2] = info;',
		'r[3] = (unsigned char)(start_us & 0xFF);',
		'r[4] = (unsigned char)((start_us >> 8) & 0xFF);',
		'r[5] = (unsigned char)((start_us >> 16) & 0xFF);',
		'r[6] = (unsigned char)(dur_us & 0xFF);',
		'r[7] = (unsigned char)((dur_us >> 8) & 0xFF);',
		'g_head++;',
		'__asm__ volatile("msr primask, %0" : : "r"(prim) : "memory");',
	]
	got_write := body_of(lines, 'static void push_rec(')
	assert got_write == want_write, 'push_rec\'s body changed.\n got: ${got_write}\nwant: ${want_write}\nThe 8-byte record is the wire format a dump decodes: the eid carries kind and the forwarded point id, bytes 6-7 the duration little-endian, and the only early exit is the frozen-for-dump `if (!g_capturing)` guard. If this change is intended, update want_write in the same commit.'
}

// body_of returns a function's body as trimmed, comment-free, non-empty lines: from the line
// matching `signature` to the closing brace in column 0. The opening brace line is skipped.
fn body_of(lines []string, signature string) []string {
	mut out := []string{}
	for i, l in lines {
		if !l.contains(signature) {
			continue
		}
		// Skip to the OPENING BRACE first: a signature may span lines (push_rec's does), and
		// starting at signature+1 collected its continuation as the first body line.
		//
		// The scan starts at the SIGNATURE LINE, not after it. C puts the brace on its own line, V
		// puts it on the signature — so beginning at signature+1 skipped past a V function's brace
		// entirely and collected the NEXT function's body instead, silently: the first V caller of
		// this helper got trace_fb_hook's body when it asked for io_exec_clock's, and would have
		// pinned it happily had the expected value matched.
		mut started := false
		for k in i .. lines.len {
			t := lines[k].trim_space()
			if !started {
				if t.ends_with('{') || t == '{' {
					started = true
				}
				// a closing brace in column 0 before any opening one means the signature's own body
				// was never found — return nothing rather than walk into the next function
				if k > i && lines[k].starts_with('}') {
					return []string{}
				}
				continue
			}
			if lines[k].starts_with('}') {
				return out
			}
			if t == '' {
				continue
			}
			out << t
		}
		return out
	}
	return out
}

// THE SERVICED PASS, PINNED VERBATIM — from the pass bracket `t0 :=` through the publish
// `C.io_exec_add(...)`, every executable line, indentation included. Every looser form of this test
// was defeated by an edit that preserved exactly the loose property it checked: `stmt_of` discarded
// indentation, so the record could be nested inside the freshness guard; an indent compare admitted
// a preceding `continue`; a keyword-PREFIX scan admitted the same transfer written inline as
// `if !ready { continue }`; and two rounds of pinning a SLICE — first ending at the record, then at
// `t1` — left appended point work outside the pin while it stayed outside the duration the record
// carries, and outside the `t1 - t0` sum. So the region is now bounded by the two things that make
// the measurement mean anything: the pass bracket opens it and the publish closes it. A guard, a
// reordering, an extra statement anywhere in the pass, an inline transfer, a nested record, a
// changed primitive and work appended after the record or after `t1` are one failure (codex #280).
//
// It is also the ORDERING guard, which is why the two dedicated pwm/gpio-output ordering tests are
// gone rather than kept beside it: each case names its own primitive with its record after it.
fn test_the_emitted_point_block_is_exact() {
	doc := empty_doc()
	for c in pin_cases() {
		// BOTH values of with_load. The region up to the publish must not depend on load telemetry:
		// a trace-only io image is a supported shape, and the hardware fixture has telemetry ENABLED,
		// so a regression that only appears without it would be invisible from every direction.
		for with_load in [true, false] {
			mut m := Model{}
			m.trace.on = true
			m.trace.level = 'all'
			m.io_points = c.points
			mut cells := map[string]int{}
			for i, pt in c.points {
				cells[pt.name] = i
			}
			g := emit_io_target_entry(m, doc, cells, with_load, 0).join('\n')
			hid := io_handler_id_base(m, doc)
			// the regions below name literal ids: these fixtures declare no FB handlers, so the point
			// id base is 0. That the base CONTINUES the handler numbering is
			// test_io_ids_start_past_every_fb_handler's claim, not this one.
			assert hid == 0, '${c.name}: the point id base is ${hid}, not 0 — the pinned regions name p0/p1 and u32(0)/u32(1), and this fixture declares no FB handlers'
			got := pass_region(g)
			assert got == c.want, '${c.name} (with_load=${with_load}): the emitted pass changed.\n got: ${got}\nwant: ${c.want}\nThe pass bracket must open the region and the exec publish must close it, each point\'s record must sit at its own block\'s level with nothing between it and the point\'s work, and nothing else may appear. If this change is intended, update the case in pin_cases() in the same commit — the point of pinning the pass is that what a point measures, and what the aggregate publishes, cannot drift silently (REQ-IO-025).'
		}
	}
}

struct PinCase {
	name   string
	points []IoPoint
	want   []string
}

// One case per emitted point shape. A kind/direction with no case here has no test at all, and the
// LAST case is the sub-rated one: every other fixture runs its point at the base tick, so the
// `mult > 1` gate that wraps a slower point stayed unexecuted — an early transfer added ahead of a
// gated point's bracket would have lost its records on every slower point while all four
// base-rate cases and the silicon fixture (one 10 ms point) stayed green (codex on #280).
fn pin_cases() []PinCase {
	one := fn (kind string, output bool) []IoPoint {
		return [
			IoPoint{
				name:      'P'
				kind:      kind
				output:    output
				period_ms: 10
				ch:        0
			},
		]
	}
	return [
		PinCase{
			name:   'gpio/in'
			points: one('gpio', false)
			want:   [
				'\t\tt0 := C.board_now_us()',
				'\t\tp0_t0 := C.board_now_us()',
				'\t\tif p_v := io.gpio_read_checked(0) {',
				'\t\t\tC.ioc_pub(0, if p_v { u32(1) } else { u32(0) }, u32(0))',
				'\t\t}',
				'\t\tC.trace_fb(u32(0), p0_t0, u32(C.board_now_us() - p0_t0))',
				'\t\tt1 := C.board_now_us()',
				'\t\tC.io_exec_add(u32(t1 - t0))',
			]
		},
		PinCase{
			name:   'gpio/out'
			points: one('gpio', true)
			want:   [
				'\t\tt0 := C.board_now_us()',
				'\t\tp0_t0 := C.board_now_us()',
				'\t\tmut p_a := u32(0)',
				'\t\tmut p_b := u32(0)',
				'\t\tif C.ioc_get_ever(0, &p_a, &p_b) != 0 {',
				'\t\t\tio.gpio_write(0, p_a != 0)',
				'\t\t}',
				'\t\tC.trace_fb(u32(0), p0_t0, u32(C.board_now_us() - p0_t0))',
				'\t\tt1 := C.board_now_us()',
				'\t\tC.io_exec_add(u32(t1 - t0))',
			]
		},
		PinCase{
			name:   'adc/in'
			points: one('adc', false)
			want:   [
				'\t\tt0 := C.board_now_us()',
				'\t\tp0_t0 := C.board_now_us()',
				'\t\tif p_v := io.adc_read_checked(0) {',
				'\t\t\tC.ioc_pub(0, p_v, u32(0))',
				'\t\t}',
				'\t\tC.trace_fb(u32(0), p0_t0, u32(C.board_now_us() - p0_t0))',
				'\t\tt1 := C.board_now_us()',
				'\t\tC.io_exec_add(u32(t1 - t0))',
			]
		},
		PinCase{
			name:   'pwm/out'
			points: one('pwm', true)
			want:   [
				'\t\tt0 := C.board_now_us()',
				'\t\tp0_t0 := C.board_now_us()',
				'\t\tmut p_a := u32(0)',
				'\t\tmut p_b := u32(0)',
				'\t\tif C.ioc_get_ever(0, &p_a, &p_b) != 0 {',
				'\t\t\tio.pwm_write(0, p_a)',
				'\t\t}',
				'\t\tC.trace_fb(u32(0), p0_t0, u32(C.board_now_us() - p0_t0))',
				'\t\tt1 := C.board_now_us()',
				'\t\tC.io_exec_add(u32(t1 - t0))',
			]
		},
		PinCase{
			name:   'a sub-rated point beside a base-rate one'
			points: [
				IoPoint{
					name:      'Fast'
					kind:      'gpio'
					output:    false
					period_ms: 10
					ch:        0
				},
				IoPoint{
					name:      'Slow'
					kind:      'adc'
					output:    false
					period_ms: 100
					ch:        1
				},
			]
			want: [
				'\t\tt0 := C.board_now_us()',
				'\t\tp0_t0 := C.board_now_us()',
				'\t\tif fast_v := io.gpio_read_checked(0) {',
				'\t\t\tC.ioc_pub(0, if fast_v { u32(1) } else { u32(0) }, u32(0))',
				'\t\t}',
				'\t\tC.trace_fb(u32(0), p0_t0, u32(C.board_now_us() - p0_t0))',
				'\t\tif (tick + 1) % 10 == 0 {',
				'\t\t\tp1_t0 := C.board_now_us()',
				'\t\t\tif slow_v := io.adc_read_checked(1) {',
				'\t\t\t\tC.ioc_pub(1, slow_v, u32(0))',
				'\t\t\t}',
				'\t\t\tC.trace_fb(u32(1), p1_t0, u32(C.board_now_us() - p1_t0))',
				'\t\t}',
				'\t\tt1 := C.board_now_us()',
				'\t\tC.io_exec_add(u32(t1 - t0))',
			]
		},
	]
}

// pass_region: the emitted io pass — its `t0 :=` bracket line through the `C.io_exec_add(...)` that
// publishes the sum, comment-free, blank lines dropped, trailing space normalised, INDENTATION KEPT.
// Indentation is half the evidence: a record moved inside a freshness guard, or a point moved inside
// another point's gate, must not compare equal.
//
// The bounds are the measurement's own bounds, and that is deliberate. Pinning to the record left
// work after it unpinned; pinning to `t1` left work between `t1` and the publish unpinned — and both
// escape the point's duration AND the pass sum while every marker-ordering check stays green. A
// missing record, or one emitted before its bracket, does not match either.
fn pass_region(src string) []string {
	mut out := []string{}
	mut on := false
	for l in strip_comments(src) {
		if l.trim_space().starts_with('t0 := C.board_now_us()') {
			on = true
		}
		if !on {
			continue
		}
		t := l.trim_right(' \t')
		if t.trim_space() == '' {
			continue // a comment-only line is not executable work
		}
		out << t
		if l.contains('C.io_exec_add(') {
			break
		}
	}
	return out
}

// THE GUARD AGAINST A DEAD ARM. Twice an arm of the operation match went unexercised — pwm, then
// gpio_write — each time leaving a point shape whose ordering nothing checked, and the pwm one is
// the shape the hardware fixture actually uses. The pinned blocks above name each primitive; this
// proves the emitter reaches it as CODE for every kind/direction, so an arm with no case there
// fails here instead of silently never running (codex on #280).
fn test_every_operation_arm_is_exercised() {
	doc := empty_doc()
	cases := [
		['gpio', 'in', 'io.gpio_read_checked('],
		['gpio', 'out', 'io.gpio_write('],
		['adc', 'in', 'io.adc_read_checked('],
		['pwm', 'out', 'io.pwm_write('],
	]
	for c in cases {
		mut m := Model{}
		m.trace.on = true
		m.trace.level = 'all'
		m.io_points = [
			IoPoint{
				name:      'P'
				kind:      c[0]
				output:    c[1] == 'out'
				period_ms: 10
				ch:        0
			},
		]
		g := emit_io_target_entry(m, doc, {
			'P': 0
		}, true, 0).join('\n')
		hid := io_handler_id_base(m, doc)
		mut emits := false
		for l in strip_comments(g) {
			if l.contains(c[2]) {
				emits = true
			}
		}
		assert emits, 'a ${c[0]} ${c[1]} point emits no ${c[2]} as CODE — the operation match has an arm no fixture reaches, or the operation survives only as a comment'
		lines := strip_comments(g)
		mut i_op := -1
		mut i_rec := -1
		for k, l in lines {
			if l.contains(c[2]) {
				i_op = k
			}
			if l.contains('C.trace_fb(u32(${hid}),') {
				i_rec = k
			}
		}
		assert i_rec > i_op, '${c[0]} ${c[1]}: records at ${i_rec}, before its ${c[2]} at ${i_op}'
	}
}

// The FB loop must CONSUME the counter. Everything else about io_exec_us proves the accumulator
// exists, accumulates, and is readable — not that the generated dispatch subtracts it. A regression
// from run_profiled_excl to run_profiled leaves the counter advancing, every source check passing
// and the silicon script (which reads g_io_exec_us directly) green, while FB load accounting once
// again charges io preemption to the handlers. loom/loom_test.v only covers the subtraction once a
// preemption function HAS been supplied (codex on #280).
fn test_the_fb_loop_subtracts_the_io_counter() {
	// GENERATES what it asserts on. The first version read
	// examples/system_full/nodes/domain/gen/loom_gen.v and returned quietly when absent — and that
	// path is gitignored (.gitignore: examples/*/nodes/*/gen/) while CI runs the tool unit tests
	// BEFORE example generation, so in the gate that matters the test asserted NOTHING and a
	// run_profiled_excl -> run_profiled regression would still have been recorded as passing
	// REQ-IO-025. I had even written a comment rationalising the skip (codex on #280).
	//
	// Running the real sysgen + loom2v rather than building a Model fixture: emit_run_target needs
	// a nearly complete model to reach the dispatch, and an unrepresentative fixture is precisely
	// how this assertion would go vacuous a second time.
	root := @VMODROOT
	tmp := os.join_path(os.temp_dir(), 'io_dispatch_${os.getpid()}')
	os.mkdir_all(tmp) or {
		assert false, 'mkdir ${tmp}: ${err}'
		return
	}
	defer {
		os.rmdir_all(tmp) or {}
	}
	sys_toml := os.join_path(root, 'examples', 'system_full', 'system.toml')
	lower := os.execute('${@VEXE} -enable-globals run ${os.join_path(root, 'tools', 'sysgen')} ${sys_toml} --out ${tmp}')
	assert lower.exit_code == 0, 'sysgen failed, so this test cannot assert on a real emitted loop: ${lower.output.trim_space()}'
	glue := os.join_path(tmp, 'glue.v')
	gen := os.execute('${@VEXE} -enable-globals run ${os.join_path(root, 'tools', 'loom2v')} ${os.join_path(tmp,
		'gen-domain.toml')} ${os.join_path(tmp, 'compute.dbc')} ${os.join_path(tmp, 'sig.v')} ${os.join_path(tmp,
		'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	assert gen.exit_code == 0, 'loom2v failed on the lowered domain config: ${gen.output.trim_space()}'
	src := os.read_file(glue) or {
		assert false, 'loom2v wrote no glue at ${glue}: ${err}'
		return
	}
	dispatches := dispatches_of(src)
	assert dispatches.len == 1, 'the emitted loop has ${dispatches.len} profiled dispatches, want exactly 1 — a second services handlers twice: ${dispatches}'
	assert dispatches[0] == 'sched.run_profiled_excl(trace_clock, io_exec_clock)', 'the FB dispatch is `${dispatches[0]}` — with io points and trace level="all" it must be run_profiled_excl(trace_clock, io_exec_clock), or handler load charges io preemption again'
	clock_body := io_clock_body(src)
	assert clock_body == ['return C.io_exec_us()'], 'io_exec_clock\'s body is ${clock_body} — it must be nothing but `return C.io_exec_us()`, because the dispatch subtracts whatever this returns and a guarded or constant return disables the exclusion while every other check stays green'

	// THE OTHER BRANCH. emit_run_target dispatches from two places — one for a partition with a
	// single local thread and one for several — and the config above only ever reaches the first,
	// because domain's CM7 partition has one thread (`fast`; the second partition is the external
	// CM4 image). Counting the call literals in gen.v was the previous form of this check, and it
	// could not tell which branch emits them: flipping the multi-thread branch's io predicate to
	// false leaves both counts unchanged while every handler on a multi-thread io node charges io
	// preemption to itself (codex on #280). So lower a second time with a two-thread partition and
	// read the dispatch it actually emits.
	multi_toml := two_thread_variant(tmp)
	glue_m := os.join_path(tmp, 'glue_multi.v')
	gen_m := os.execute('${@VEXE} -enable-globals run ${os.join_path(root, 'tools', 'loom2v')} ${multi_toml} ${os.join_path(tmp,
		'compute.dbc')} ${os.join_path(tmp, 'sig_m.v')} ${os.join_path(tmp, 'ports_m.v')} ${glue_m} ${os.join_path(tmp,
		'manifest_multi.csv')}')
	assert gen_m.exit_code == 0, 'loom2v failed on the two-thread variant: ${gen_m.output.trim_space()}'
	src_m := os.read_file(glue_m) or {
		assert false, 'loom2v wrote no glue at ${glue_m}: ${err}'
		return
	}
	// PROOF the multi-thread branch was reached, not merely that two dispatches appeared: only that
	// branch emits a `run_<thread>()` per [[partition.thread]]. Without this the variant could fail
	// to take effect — a mis-inserted thread block, or the toml comment trap (vlang/v#27684) eating
	// the key — and the assertions below would pass against the single-thread emitter again.
	// PER THREAD, inside its own run function — not a count over the file. Counting admits
	// `run_fast()` emitting two correct dispatches while `run_aux()` emits none: both functions
	// exist, the total is still two, every per-call equality still passes, and the fast handlers are
	// serviced twice while the aux handlers are never serviced at all (codex on #280).
	m_lines := strip_comments(src_m)
	for thr in ['fast', 'aux'] {
		body := body_of(m_lines, 'fn run_${thr}()')
		// also the proof the multi-thread branch was REACHED, not merely that two dispatches
		// appeared: only that branch emits a run_<thread>() per [[partition.thread]]. Without it the
		// variant could fail to take effect — a mis-inserted thread block, or the toml comment trap
		// (vlang/v#27684) eating the key — and this would re-test the single-thread emitter.
		assert body.len > 0, 'the two-thread variant emits no `fn run_${thr}()` — the multi-thread emitter was not reached, so the fixture did not take effect'
		mut per_thread := []string{}
		for l in body {
			if l.contains('sched.run_profiled') {
				per_thread << l
			}
		}
		assert per_thread.len == 1, 'run_${thr}() has ${per_thread.len} profiled dispatches, want exactly 1 — none leaves that thread\'s handlers unserviced and two services them twice: ${per_thread}'
		assert per_thread[0] == 'sched.run_profiled_excl(trace_clock, io_exec_clock)', 'run_${thr}() dispatches `${per_thread[0]}` — with io points and trace level="all" every thread must exclude the io exec counter, or its handlers charge io preemption'
	}
	// and none anywhere else in the file: two threads, two dispatches, both inside their own loops
	dispatches_m := dispatches_of(src_m)
	assert dispatches_m.len == 2, 'the two-thread variant emits ${dispatches_m.len} profiled dispatches in total, want the two inside run_fast() and run_aux(): ${dispatches_m}'
	clock_body_m := io_clock_body(src_m)
	assert clock_body_m == ['return C.io_exec_us()'], 'io_exec_clock\'s body in the two-thread variant is ${clock_body_m} — every thread subtracts whatever it returns'
}

// The profiled dispatches of an emitted glue, and whether io_exec_clock() reads the io counter.
// EVERY dispatch, not the last: overwriting a single variable validated only the final match, so an
// extra `sched.run_profiled(...)` before the expected call left the last value correct and the test
// passing — while that dispatch still charged io preemption, and an extra call services handlers
// twice (codex on #280).
fn dispatches_of(src string) []string {
	mut dispatches := []string{}
	for l in strip_comments(src) {
		if l.contains('sched.run_profiled') {
			dispatches << l.trim_space()
		}
	}
	return dispatches
}

// io_exec_clock's body, which is what the dispatch above actually subtracts. A whole-file lookup for
// `return C.io_exec_us()` was the previous form and proved only that the text appears SOMEWHERE:
// wrapping it in `if false { ... }` with a `return 0` after left that check and the exact
// run_profiled_excl(..., io_exec_clock) assertion both green, while every handler subtracted zero
// and charged io preemption again (codex on #280). Pin the body instead — the same body_of the C-side
// recorder pin uses.
fn io_clock_body(src string) []string {
	return body_of(strip_comments(src), 'fn io_exec_clock(')
}

// The lowered domain config plus a SECOND thread in its CM7 partition, written beside it. Derived
// from the real lowering rather than hand-built, so the only difference from the verified config is
// the thread count — the representativeness the branch check needs is inherited, not invented. The
// added FB's handler reads and writes nothing: a local signal cannot cross threads (loom2v rejects
// it, the IOC fan-out is not generated), and the dispatch shape does not depend on its ports.
fn two_thread_variant(tmp string) string {
	path := os.join_path(tmp, 'gen-domain.toml')
	src := os.read_file(path) or {
		assert false, 'cannot read the lowered config at ${path}: ${err}'
		return ''
	}
	anchor := '  [[partition.thread]]\n  name = "fast"\n'
	assert src.count(anchor) == 1, 'the lowered domain config no longer declares exactly one `fast` thread the way this fixture inserts after — the variant would not become multi-thread'
	// the trailing comment is not decoration: a nested [[ ]] block's last key needs one or V's toml
	// parser drops the next key (vlang/v#27684, see the header of the lowered file)
	out := src.replace(anchor, anchor + '\n  [[partition.thread]]\n  name = "aux"\n') +
		'\n[[fb]]\nname   = "AuxCtrl"\nthread = "aux"\n\n  [[fb.handler]]\n  name      = "on_100ms"\n  period_ms = 100 # terminates the nested block (vlang/v#27684)\n'
	dst := os.join_path(tmp, 'gen-domain-multi.toml')
	os.write_file(dst, out) or {
		assert false, 'cannot write the two-thread variant to ${dst}: ${err}'
		return ''
	}
	return dst
}
