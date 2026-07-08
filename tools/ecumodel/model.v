// ecumodel — the shared ecu.toml helpers + partition/thread/fb VALIDATION rules. loom2v (the
// generator) and ecucheck (the up-front validator) both call `validate()`, so the cross-field
// rules can't drift between the gate and the generator (they had, twice, when duplicated).
//
// `validate()` collects EVERY structural error (empty slice = valid) with tool-neutral
// messages: ecucheck reports them; loom2v panics if any (then builds its maps assuming valid
// input). The rules encoded here are exactly loom2v's current capabilities:
//   - every partition has a `name` (a valid identifier) and >=1 [[partition.thread]];
//   - thread names are GLOBALLY unique (so an fb names one and its partition is derived);
//   - only ONE thread per partition for now (per-thread schedulers not generated yet);
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
		} else if nthreads > 1 {
			errs << 'partition "${pname}" declares ${nthreads} threads — multiple threads per partition is not generated yet (one scheduler per partition today); declare a single [[partition.thread]]'
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
			if lvl !in ['thread', 'thread+isr', 'thread+fb', 'all'] {
				errs << '[trace] level "${lvl}" is invalid (thread | thread+isr | thread+fb | all)'
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
			// A dump block is one ISO-TP payload — an 8-byte block header + the records — and
			// comm/isotp.max_payload (520) is sized to hold a header + 64 records, so the ring
			// can't exceed 64 records today. Reject it at the gate, before codegen.
			if v is i64 {
				if v < 1 || v > 64 {
					errs << '[trace] buffer_records ${v} out of range (1..64 — a dump block is one ISO-TP payload: an 8-byte header + up to 64 records)'
				}
			} else {
				errs << '[trace] buffer_records must be an integer (1..64)'
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
