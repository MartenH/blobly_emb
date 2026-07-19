// ecumodel — the shared ecu.toml helpers + partition/thread/fb VALIDATION rules. loom2v (the
// generator) and ecucheck (the up-front validator) both call `validate()`, so the cross-field
// rules can't drift between the gate and the generator (they had, twice, when duplicated).
//
// `validate()` collects EVERY structural error (empty slice = valid) with tool-neutral
// messages: ecucheck reports them; loom2v panics if any (then builds its maps assuming valid
// input). The rules encoded here are exactly loom2v's current capabilities:
//   - every partition has a `name` (a valid identifier) and >=1 [[partition.thread]];
//   - thread names are GLOBALLY unique (so an fb names one and its partition is derived);
//   - at most FOUR threads per partition (one scheduler + TCB/stack + load slot per thread);
//   - every fb has a unique `name` and a `thread` that resolves to a declared thread;
//   - every handler has exactly the `period_ms` trigger (`irq` is reserved, not generated yet).
module ecumodel

import toml

// toml_arr returns the array of tables under `key`, or empty when the key is absent — so an
// ecu.toml that omits an optional section doesn't phantom-iterate a single empty entry.
pub fn toml_arr(doc toml.Doc, key string) []toml.Any {
	if v := doc.value_opt(key) {
		return v.array()
	}
	return []toml.Any{}
}

// ident_ok reports whether s is a safe name — [A-Za-z_][A-Za-z0-9_]* — for both V codegen
// (names become struct/field identifiers) and the manifest CSV (a comma/space corrupts a row).
pub fn ident_ok(s string) bool {
	if s == '' {
		return false
	}
	for i, c in s {
		alpha := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
		if i == 0 {
			if !alpha {
				return false
			}
		} else if !(alpha || (c >= `0` && c <= `9`)) {
			return false
		}
	}
	return true
}

fn str_of(m map[string]toml.Any, key string) string {
	if v := m[key] {
		if v is string {
			return v
		}
	}
	return ''
}

fn arr_of(m map[string]toml.Any, key string) []toml.Any {
	if v := m[key] {
		if v is []toml.Any {
			return v
		}
	}
	return []toml.Any{}
}

// validate returns every partition/thread/fb/handler structural error (empty = valid).
pub fn validate(doc toml.Doc) []string {
	mut errs := []string{}
	mut part_names := map[string]bool{}
	mut thread_part := map[string]string{} // thread -> partition (globally unique)
	mut fb_names := map[string]bool{}

	for p in toml_arr(doc, 'partition') {
		pm := p.as_map()
		pname := str_of(pm, 'name')
		if 'name' !in pm {
			errs << 'a [[partition]] is missing `name`'
		} else if !ident_ok(pname) {
			errs << 'partition name "${pname}" is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)'
		} else if pname in part_names {
			errs << 'duplicate partition name "${pname}" — partition names must be unique'
		} else {
			part_names[pname] = true
		}
		// core is required — omitting it would silently pin the partition to core 0 (loom2v
		// and cfg2v default to 0), emitting the wrong partition table / manifest.
		if 'core' !in pm {
			errs << 'partition "${pname}" is missing `core` (the core index it is pinned to)'
		}
		mut nthreads := 0
		for t in arr_of(pm, 'thread') {
			nthreads++
			tm := t.as_map()
			tname := str_of(tm, 'name')
			if 'name' !in tm {
				errs << 'partition "${pname}" has a [[partition.thread]] missing `name`'
			} else if !ident_ok(tname) {
				errs << 'thread name "${tname}" (partition "${pname}") is not a valid identifier'
			} else if tname in thread_part {
				errs << 'duplicate thread name "${tname}" — thread names must be globally unique (already in partition "${thread_part[tname]}")'
			} else {
				thread_part[tname] = pname
			}
		}
		if nthreads == 0 {
			errs << 'partition "${pname}" declares no [[partition.thread]] — every partition needs at least one thread'
		} else if nthreads > 4 {
			errs << 'partition "${pname}" declares ${nthreads} threads — at most 4 are generated (one scheduler per thread; static TCB/stack + a load slot each)'
		}
	}

	for c in toml_arr(doc, 'fb') {
		cm := c.as_map()
		fbname := str_of(cm, 'name')
		if 'name' !in cm {
			errs << 'a [[fb]] is missing `name`'
		} else if !ident_ok(fbname) {
			errs << 'fb name "${fbname}" is not a valid identifier'
		} else if fbname in fb_names {
			errs << 'duplicate fb name "${fbname}" — fb names must be unique'
		} else {
			fb_names[fbname] = true
		}
		thr := str_of(cm, 'thread')
		if 'thread' !in cm {
			errs << 'fb "${fbname}" is missing `thread` (thread = "<a globally-unique [[partition.thread]] name>")'
		} else if thr !in thread_part {
			errs << 'fb "${fbname}" names unknown thread "${thr}" (no [[partition.thread]] with that name)'
		}
		mut nhandlers := 0
		for h in arr_of(cm, 'handler') {
			nhandlers++
			hm := h.as_map()
			hname := str_of(hm, 'name')
			if 'name' !in hm {
				errs << 'fb "${fbname}" has a [[fb.handler]] missing `name`'
			} else if !ident_ok(hname) {
				errs << 'fb "${fbname}" handler name "${hname}" is not a valid identifier'
			}
			has_period := 'period_ms' in hm
			has_irq := 'irq' in hm
			if has_irq {
				errs << 'fb "${fbname}" handler "${hname}": irq-triggered handlers are not generated yet (reserved trigger); use period_ms'
			} else if !has_period {
				errs << 'fb "${fbname}" handler "${hname}" needs a trigger — period_ms'
			}
		}
		// an fb with no handler is never scheduled (no sched.every, no manifest row) — reject
		// it rather than silently emit a dead fb.
		if nhandlers == 0 {
			errs << 'fb "${fbname}" has no [[fb.handler]] — an fb needs at least one handler'
		}
	}

	// [io] — physical IO points (docs/io.md). The reserved-name rule is load-bearing:
	// an endpoint that matches no bus silently becomes a phantom partition in the
	// generator, so "io" must be impossible to shadow. NOTE: this section must stay
	// BEFORE [trace] — trace's disabled-path returns early.
	mut bus_names := map[string]bool{}
	if bv := doc.value_opt('bus') {
		for bname, _ in bv.as_map() {
			bus_names[bname] = true
		}
	}
	for reserved_holder in ['partition', 'thread', 'bus'] {
		names := match reserved_holder {
			'partition' { part_names.keys() }
			'thread' { thread_part.keys() }
			else { bus_names.keys() }
		}
		if 'io' in names {
			errs << 'a ${reserved_holder} is named "io" — reserved endpoint name (io points, docs/io.md)'
		}
	}
	errs << validate_io(doc, part_names, thread_part, bus_names)

	// [trace] — the runtime-observability block loom2v generates the trace wiring from. Validate
	// the enums loom2v switches on (level, mode), the numeric ranges (pre_pct, buffer_records),
	// and the CAN channel the traffic binds to. Frame ids are handled by loom2v (see below).
	if tr := doc.value_opt('trace') {
		trm := tr.as_map()
		// A [trace] block is active unless explicitly disabled — so it can be turned off (no bus
		// needed) without deleting the block. Disabled: nothing to validate (this is the last
		// section, so returning here skips only [trace]'s rules).
		if !(trm['enabled'] or { toml.Any(true) }).bool() {
			return errs
		}
		mut buses := map[string]bool{}
		if bv := doc.value_opt('bus') {
			for bname, _ in bv.as_map() {
				buses[bname] = true
			}
		}
		// The cmd/rsp + dump ride a CAN channel: `trace.bus`, or `[telemetry].bus` by default.
		// Whichever applies must resolve to a declared [bus.X], else the traffic has no bus.
		mut tbus := str_of(trm, 'bus')
		mut bus_src := 'trace.bus'
		if 'bus' !in trm {
			bus_src = '[telemetry].bus (default)'
			if telem := doc.value_opt('telemetry') {
				tbus = str_of(telem.as_map(), 'bus')
			}
		}
		if tbus == '' {
			errs << '[trace] has no bus — set trace.bus (or [telemetry].bus) to a declared [bus.X]'
		} else if tbus !in buses {
			errs << '[trace] bus "${tbus}" from ${bus_src} is not a declared [bus.${tbus}]'
		}
		if 'level' in trm {
			lvl := str_of(trm, 'level')
			if lvl !in ['fb', 'thread', 'thread+isr', 'thread+fb', 'all'] {
				errs << '[trace] level "${lvl}" is invalid (fb | thread | thread+isr | thread+fb | all)'
			}
		}
		if 'mode' in trm {
			md := str_of(trm, 'mode')
			if md !in ['ring', 'oneshot'] {
				errs << '[trace] mode "${md}" is invalid (ring | oneshot)'
			}
		}
		// pre_pct/buffer_records: only range-check actual integers. .i64() returns 0 for a
		// non-numeric value, so a string like "150" would slip through when loom2v calls
		// validate() without ecucheck's type pass first — check the type here too.
		if v := trm['pre_pct'] {
			if v is i64 {
				if v < 0 || v > 100 {
					errs << '[trace] pre_pct ${v} out of range (0..100)'
				}
			} else {
				errs << '[trace] pre_pct must be an integer (0..100)'
			}
		}
		if v := trm['push_ms'] {
			if v is i64 {
				if v < 0 {
					errs << '[trace] push_ms ${v} must be >= 0 (0 disables the HandlerStat heartbeat)'
				}
			} else {
				errs << '[trace] push_ms must be an integer (0 = off)'
			}
		}
		if v := trm['buffer_records'] {
			// The dump streams the window as MULTIPLE self-describing blocks (each ~one
			// transport payload, header more-flag until the last), so the ring is no longer
			// capped by a single payload. The bound left is memory sanity — 4096 records is
			// 32 KB of ring — and the ThreadX exec-hook path also can't snapshot more than
			// the recorder's RING_CAP (256 in trace_hooks.c).
			if v is i64 {
				if v < 1 || v > 4096 {
					errs << '[trace] buffer_records ${v} out of range (1..4096 — the dump is multi-block; 4096 records = 32 KB of ring)'
				}
			} else {
				errs << '[trace] buffer_records must be an integer (1..4096)'
			}
		}
		// Frame ids (cmd_id/rsp_id/stat_id/record_id/dump_fc_id) are each either a literal CAN id
		// (used as-is — allocating a non-colliding id is the author's responsibility) or the name
		// of a message in bus.dbc. The name case is resolved + checked-to-exist by loom2v, which
		// loads the DBC; this validator doesn't, so it does not police the ids here.

		// trigger: only "overrun" is generated today. Any other/misspelled source would silently
		// produce a capture that never freezes, so reject it. "overrun" needs a positive budget_us
		// (else the ring never freezes and a dump has nothing to read).
		if tg := trm['trigger'] {
			tgm := tg.as_map()
			src := str_of(tgm, 'source')
			if src == '' {
				errs << '[trace] trigger table has no source — set source = "overrun", or omit the whole [trace.trigger] table for no trigger'
			} else if src != 'overrun' {
				errs << '[trace] trigger source "${src}" is not supported (only "overrun" is generated today)'
			} else {
				b := tgm['budget_us'] or { toml.Any(0) }
				if !(b is i64) || b.i64() <= 0 {
					errs << '[trace] trigger source "overrun" needs a positive budget_us (µs a handler may run before the ring freezes)'
				}
			}
		}
	}
	return errs
}

// validate_io checks the [[io.gpio]] points against the io-bound signals (docs/io.md
// P1: GPIO only, single consumer). Every rule here failed loudly in design review
// before it could fail silently on a bench — keep them exhaustive.

fn validate_io(doc toml.Doc, part_names map[string]bool, thread_part map[string]string, bus_names map[string]bool) []string {
	mut errs := []string{}
	// gather points across the io kinds (gpio/adc/pwm), tagged so kind-specific
	// rules (field type, direction, pwm carrier) branch while the shared rules
	// (name, pin exclusivity, period, one-to-one binding) run once (docs/io.md).
	mut points := []toml.Any{}
	mut point_kind := []string{}
	if io_tbl := doc.value_opt('io') {
		iom := io_tbl.as_map()
		for k in ['gpio', 'adc', 'pwm'] {
			for pt in arr_of(iom, k) {
				points << pt
				point_kind << k
			}
		}
	}

	// signals by name, plus the io-bound set (from/to = "io") — scanned BEFORE
	// any early return: an io-bound signal with NO [io] table (or no points)
	// must still fail the reverse one-to-one check, not slip past as a phantom
	mut sig_from := map[string]string{}
	mut sig_to := map[string]string{}
	mut sig_nfields := map[string]int{}
	mut sig_ftype := map[string]string{} // the single field's type when nfields == 1
	mut sig_has_transport := map[string]bool{}
	for sg in toml_arr(doc, 'signal') {
		sm := sg.as_map()
		sname := str_of(sm, 'name')
		sig_from[sname] = str_of(sm, 'from')
		sig_to[sname] = str_of(sm, 'to')
		sig_has_transport[sname] = 'transport' in sm
		if f := sm['fields'] {
			fm := f.as_map()
			sig_nfields[sname] = fm.len
			if fm.len == 1 {
				for _, ftyp in fm {
					sig_ftype[sname] = ftyp.string()
				}
			}
		}
	}
	mut has_io_sig := false
	for sname, from in sig_from {
		if from == 'io' || sig_to[sname] == 'io' {
			has_io_sig = true
		}
	}
	if points.len == 0 && !has_io_sig {
		return errs // nothing io-related to validate
	}
	// a [[did]] pointing at an io signal would emit its own ioc_acquire — a
	// second reader on the SPSC channel, stealing samples from the real consumer
	for d in toml_arr(doc, 'did') {
		dsig := str_of(d.as_map(), 'signal')
		if dsig != '' && (sig_from[dsig] == 'io' || sig_to[dsig] == 'io') {
			errs << 'diagnostic DID reads io signal ${dsig} — a second reader on a single-reader channel; mirror it through an FB-owned signal instead'
		}
	}
	if points.len > 32 {
		errs << '${points.len} io points configured — the driver backend holds at most 32 (BLOB_IO_MAX)'
	}

	// reads/writes fan-in per signal across every handler (P1: exactly one each
	// side), plus the partition each access runs in — the accessor must live in
	// the signal's DECLARED application partition or the transport derivation
	// would use the wrong core
	mut readers := map[string]int{}
	mut writers := map[string]int{}
	mut reader_part := map[string]string{}
	mut writer_part := map[string]string{}
	for c in toml_arr(doc, 'fb') {
		cm := c.as_map()
		fb_part := thread_part[str_of(cm, 'thread')] or { '' }
		for h in arr_of(cm, 'handler') {
			hm := h.as_map()
			for r in arr_of(hm, 'reads') {
				readers[r.string()]++
				reader_part[r.string()] = fb_part
			}
			for w in arr_of(hm, 'writes') {
				writers[w.string()]++
				writer_part[w.string()] = fb_part
			}
		}
	}

	mut fastest := i64(0)
	mut periods := map[string]i64{}
	mut period_kind := map[string]string{}
	mut seen_point := map[string]bool{}
	mut seen_pin := map[string]bool{}
	for pi, p in points {
		kind := point_kind[pi]
		pm := p.as_map()
		name := str_of(pm, 'name')
		if !ident_ok(name) {
			errs << 'io.${kind} point name "${name}" is not a valid identifier'
			continue
		}
		if name.len > 63 {
			// the driver mirrors names into fixed 64-byte buffers; a longer name
			// would silently truncate — two prefix-sharing names on one mirror file
			errs << 'io.${kind} point name "${name}" is ${name.len} bytes — the driver name buffer holds at most 63'
			continue
		}
		if name in seen_point {
			errs << 'duplicate io.${kind} point "${name}" — one point per signal (one-to-one binding)'
			continue
		}
		seen_point[name] = true
		pin := str_of(pm, 'pin')
		// exclusivity by NAME only: the model is backend-neutral (AGENTS.md —
		// pin GRAMMAR belongs below the driver boundary; an STM32 'PB0', an
		// 'GPIO17', a 'P0.3' are all opaque here). The stm32 backend rejects
		// non-canonical spellings at cfg (io_stm32.c pin_parse: no leading
		// zeros), so one pad has exactly one accepted spelling and string
		// uniqueness is sufficient (codex on emb#150, both rounds).
		if pin in seen_pin {
			errs << 'io.${kind} "${name}" reuses pad "${pin}" — one physical pad cannot serve two points'
		}
		seen_pin[pin] = true
		mut period := i64(0)
		if v := pm['period_ms'] {
			if v is i64 {
				period = v
			}
		}
		if period < 1 {
			errs << 'io.${kind} "${name}" period_ms must be >= 1 ms (the Loom tick)'
		} else {
			periods[name] = period
			period_kind[name] = kind
			if fastest == 0 || period < fastest {
				fastest = period
			}
		}

		// binding: the signal must exist, with io on exactly one side and the
		// application (a partition or thread) on the other
		if name !in sig_from {
			errs << 'io.${kind} "${name}" has no [[signal]] of that name (one-to-one binding)'
			continue
		}
		from := sig_from[name]
		to := sig_to[name]
		is_input := from == 'io'
		is_output := to == 'io'
		if is_input == is_output { // both or neither
			errs << 'signal "${name}": an io-bound signal needs io on exactly one side (from = "io" for an input, to = "io" for an output)'
			continue
		}
		// kind-fixed direction: adc is input-only, pwm is output-only; gpio is either
		if kind == 'adc' && !is_input {
			errs << 'io.adc "${name}" is an analog INPUT — it must flow from = "io" (an ADC cannot be an output)'
		}
		if kind == 'pwm' && !is_output {
			errs << 'io.pwm "${name}" is a PWM OUTPUT — it must flow to = "io" (a PWM cannot be an input)'
		}
		mut other := if is_input { to } else { from }
		// bus check FIRST: a bus and a thread may share a name, and the alias
		// rewrite would launder a bus endpoint into a partition
		if other in bus_names {
			errs << 'signal "${name}": the non-io side is bus "${other}" — an io signal must pass through the application (REQ-IO-002), never bus-to-pin'
		} else if other in thread_part {
			other = thread_part[other] // a thread endpoint resolves to its partition
		} else if other !in part_names {
			errs << 'signal "${name}": endpoint "${other}" is not a declared partition or thread'
		}
		if sig_has_transport[name] {
			errs << 'signal "${name}": transport is derived for io signals (triple same-core, xioc cross-core) — remove the explicit transport'
		}
		// shape: exactly one field, bool, for gpio
		nf := sig_nfields[name] or { 0 }
		if nf != 1 {
			errs << 'signal "${name}": an io-bound signal carries exactly one field (found ${nf})'
		} else {
			ft := sig_ftype[name]
			if kind == 'gpio' && ft != 'bool' {
				errs << 'signal "${name}": a gpio point carries a bool field (found "${ft}")'
			} else if kind in ['adc', 'pwm'] && ft != 'u16' && ft != 'u32' {
				// a u8 cannot carry an ADC count / 0..1000 permille; an f32 has
				// no defined digital-level meaning (docs/io.md REQ-IO-019)
				errs << 'signal "${name}": an ${kind} point carries a u16 or u32 field (found "${ft}")'
			}
		}
		// producer/consumer counts: exactly one on the application side (P1),
		// nothing on the io-owned side, and the accessor in the declared partition
		// P1 generates same-core io only: fail at validation, not in build_model
		mut io_core := i64(0)
		if iov := doc.value_opt('io') {
			if cv := iov.as_map()['core'] {
				if cv is i64 {
					io_core = cv
				}
			}
		}
		for pp in toml_arr(doc, 'partition') {
			ppm := pp.as_map()
			if str_of(ppm, 'name') == other {
				if cv := ppm['core'] {
					if cv is i64 && cv != io_core {
						errs << 'signal "${name}": endpoint partition "${other}" is on core ${cv} but [io].core is ${io_core} — cross-core io arrives with the target phase'
					}
				}
				// the io thread + its IOC cell live in the LOCAL image; if the
				// non-io endpoint is a satellite (image = ...), the satellite FB
				// publishes through its cross-image xioc slot, NOT this local cell,
				// so an output stays at init / an input never reaches its consumer
				// (codex emb#150 r11). Reject until io emits into the owning image.
				img := str_of(ppm, 'image')
				is_ext := img != '' || ((ppm['external'] or { toml.Any(false) }).bool())
				if is_ext {
					errs << 'signal "${name}": io endpoint partition "${other}" is an external/satellite image — the io thread and its cell are in the LOCAL image, so the point cannot reach a satellite FB (declare the io point in the owning image)'
				}
			}
		}
		if kind == 'pwm' {
			fh := (pm['freq_hz'] or { toml.Any(0) })
			if fh !is i64 || (fh as i64) <= 0 {
				errs << 'io.pwm "${name}" needs a positive freq_hz (the carrier frequency; a zero divisor is not a timer)'
			}
			if iv := pm['init'] {
				if iv is i64 && (iv < 0 || iv > 1000) {
					errs << 'io.pwm "${name}" init must be a permille 0..1000 (the pre-publication duty)'
				}
			}
		}
		if is_output {
			if 'init' !in pm {
				errs << 'io.${kind} "${name}" is an output and must declare init (the pre-publication pin state)'
			}
			if 'default' in pm {
				errs << 'io.${kind} "${name}" is an output — default is an input\'s pre-first-sample port value; outputs declare init'
			}
			if writers[name] != 1 {
				errs << 'io output "${name}" needs exactly one writing handler (found ${writers[name]}) — zero leaves the pin at init forever, two break SPSC'
			} else if writer_part[name] != other {
				errs << 'io output "${name}" is written from partition "${writer_part[name]}" but declares endpoint "${other}" — the writer must live in the declared partition'
			}
			if readers[name] > 0 {
				errs << 'io output "${name}" appears in a handler\'s reads — the io thread owns that channel side (single-reader transport); keep the last command in FB state instead'
			}
		} else {
			if 'init' in pm {
				errs << 'io.${kind} "${name}" is an input — init belongs to outputs; an input\'s pre-first-sample port value is `default`'
			}
			if readers[name] != 1 {
				errs << 'io input "${name}" needs exactly one reading handler (found ${readers[name]}) — P1 is single-consumer (fan-out arrives with the to-list form)'
			} else if reader_part[name] != other {
				errs << 'io input "${name}" is read from partition "${reader_part[name]}" but declares endpoint "${other}" — the reader must live in the declared partition'
			}
			if writers[name] > 0 {
				errs << 'io input "${name}" appears in a handler\'s writes — the io thread is its only producer'
			}
		}
	}
	// every io-bound signal must have its point (the reverse of one-to-one)
	for sname, from in sig_from {
		if (from == 'io' || sig_to[sname] == 'io') && sname !in seen_point {
			errs << 'signal "${sname}" is io-bound but no [[io.<kind>]] point declares it — a phantom endpoint with no hardware'
		}
	}
	// harmonic periods: every period an integer multiple of the fastest
	for pname, period in periods {
		if fastest > 0 && period % fastest != 0 {
			errs << 'io.${period_kind[pname]} "${pname}" period ${period} ms is not a multiple of the fastest io period (${fastest} ms) — the io thread serves points on multiples of its tick'
		}
	}
	return errs
}
