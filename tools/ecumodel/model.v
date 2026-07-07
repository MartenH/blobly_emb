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

	// [trace] — the runtime-observability block loom2v generates a DBC + wiring from. Validate
	// the enums loom2v switches on (level, mode), numeric ranges, the CAN channel the traffic
	// binds to, and the frame ids — so a config that would emit a wrapped/colliding id or an
	// oversized ring fails at ecucheck instead of producing a bad DBC/buffer.
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
		if v := trm['pre_pct'] {
			p := v.i64() // i64, not .int() — a >32-bit value must not wrap into range
			if p < 0 || p > 100 {
				errs << '[trace] pre_pct ${p} out of range (0..100)'
			}
		}
		if v := trm['buffer_records'] {
			// TraceRsp reports records_used/capacity as u16 (comm/trace.handle_cmd), so a ring
			// above 65535 would wrap the reported size — cap it here. i64 so a >32-bit value
			// can't truncate back into range.
			n := v.i64()
			if n < 1 || n > 65535 {
				errs << '[trace] buffer_records ${n} out of range (1..65535 — TraceRsp reports it as u16)'
			}
		}
		// Frame ids: each in CAN range and all mutually distinct, so the generated DBC has no
		// wrapped/duplicate BO_ id and no two frames collide on the wire. Enabled telemetry ids
		// join the set ONLY when telemetry shares the trace bus — on a separate CAN channel they
		// can't collide. Defaults per docs/telemetry.md.
		// Read ids as i64 (not int): toml's .int() truncates to 32 bits, so a value >= 2^32 could
		// wrap into range and defeat the check below.
		mut ids := map[string]i64{}
		defaults := {
			'cmd_id':     i64(0x7E2)
			'rsp_id':     i64(0x7E3)
			'stat_id':    i64(0x7E4)
			'record_id':  i64(0x7E5)
			'dump_fc_id': i64(0x7E6)
		}
		for field, def in defaults {
			mut id := def
			if v := trm[field] {
				id = v.i64()
			}
			ids[field] = id
		}
		if telem := doc.value_opt('telemetry') {
			tm := telem.as_map()
			// only a telemetry frame on the SAME declared bus can collide (tbus != '' guards the
			// both-empty case, which is already reported as "[trace] has no bus").
			if (tm['enabled'] or { toml.Any(false) }).bool() && tbus != '' && str_of(tm, 'bus') == tbus {
				// loom2v sends CpuLoad on telem_id even when `id` is omitted (defaulting to 0), so
				// reserve that default too. detail_id only names a real frame when non-zero (0 =
				// no LoadDetail), so it's reserved only when set.
				ids['telemetry.id'] = (tm['id'] or { toml.Any(0) }).i64()
				if v := tm['detail_id'] {
					d := v.i64()
					if d != 0 {
						ids['telemetry.detail_id'] = d
					}
				}
			}
		}
		// Ids already claimed by OTHER traffic on the trace bus: ISO-TP rx/tx and NM tx + its rx
		// range. A trace id reusing one is a wire collision on that bus. (Application DBC frame
		// ids live in the .dbc, which this validator doesn't parse — that overlap isn't caught
		// here.)
		mut reserved := map[i64]string{}
		mut nm_rx_lo := i64(-1)
		mut nm_rx_hi := i64(-1)
		if tbus != '' {
			for it in toml_arr(doc, 'isotp') {
				im := it.as_map()
				if str_of(im, 'bus') == tbus {
					iname := str_of(im, 'name')
					if v := im['rx_id'] {
						reserved[v.i64()] = 'isotp "${iname}" rx_id'
					}
					if v := im['tx_id'] {
						reserved[v.i64()] = 'isotp "${iname}" tx_id'
					}
				}
			}
			if nmv := doc.value_opt('nm') {
				if nmbus := nmv.as_map()[tbus] {
					nmm := nmbus.as_map()
					if v := nmm['tx_id'] {
						reserved[v.i64()] = 'nm.${tbus} tx_id'
					}
					if v := nmm['rx_lo'] {
						nm_rx_lo = v.i64()
					}
					if v := nmm['rx_hi'] {
						nm_rx_hi = v.i64()
					}
				}
			}
		}
		// Range-check EVERY id (trace + the shared telemetry ids), then check uniqueness among the
		// in-range ones and against the other traffic already on the bus.
		mut seen := map[i64]string{}
		for label, id in ids {
			if id < 0 || id > 0x1fff_ffff {
				errs << '[trace] ${label} ${id} out of CAN id range (0..0x1FFFFFFF)'
				continue
			}
			if prev := seen[id] {
				errs << '[trace] frame id ${id} used by both ${prev} and ${label} — ids must be distinct'
			} else {
				seen[id] = label
			}
			if res := reserved[id] {
				errs << '[trace] ${label} ${id} collides with ${res} already on bus "${tbus}"'
			}
			if nm_rx_lo >= 0 && nm_rx_hi >= nm_rx_lo && id >= nm_rx_lo && id <= nm_rx_hi {
				errs << '[trace] ${label} ${id} falls in the nm.${tbus} rx range [${nm_rx_lo}..${nm_rx_hi}]'
			}
		}
	}
	return errs
}
