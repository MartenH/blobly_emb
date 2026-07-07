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
		for h in arr_of(cm, 'handler') {
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
	}
	return errs
}
