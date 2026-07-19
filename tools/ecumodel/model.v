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

	// [someip] / eth buses — must also stay BEFORE [trace] (early return below).
	errs << validate_someip(doc, part_names, thread_part, bus_names)

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
				if b !is i64 || b.i64() <= 0 {
					errs << '[trace] trigger source "overrun" needs a positive budget_us (µs a handler may run before the ring freezes)'
				}
			}
		}
	}
	return errs
}

// scalar_width returns the wire width of a fixed-width scalar field type, or 0
// for anything the derived eth layout cannot carry (strings, arrays — no fixed
// natural width, and heap-shaped types violate no-alloc in generated code).
fn scalar_width(t string) int {
	return match t {
		'bool', 'u8', 'i8' { 1 }
		'u16', 'i16' { 2 }
		'u32', 'i32', 'f32' { 4 }
		'u64', 'i64', 'f64' { 8 }
		else { 0 }
	}
}

// peer_ok reports whether s parses as an IPv4 address:port pair — narrowing
// and resolution happen in socket setup, so a bad peer must fail the build
// instead. IPv4 dotted-quad only: the static NetX path takes an IP, not a
// name (hostname support is a host-sim nicety to add if ever needed).
fn peer_ok(s string) bool {
	mut colon := -1
	for i, c in s {
		if c == `:` {
			colon = i
		}
	}
	if colon < 1 || colon == s.len - 1 {
		return false
	}
	port_str := s[colon + 1..]
	for c in port_str {
		if c < `0` || c > `9` {
			return false
		}
	}
	port := port_str.i64()
	if port < 1 || port > 65535 {
		return false
	}
	octets := s[..colon].split('.')
	if octets.len != 4 {
		return false
	}
	for o in octets {
		if o.len < 1 || o.len > 3 {
			return false
		}
		for c in o {
			if c < `0` || c > `9` {
				return false
			}
		}
		if o.i64() > 255 {
			return false
		}
	}
	return true
}

// EthLayoutCell is one derived-layout cell of an eth frame (docs/someip.md).
// The canonical order — signals in list order, fields NAME-SORTED, LE, natural
// widths, byte-aligned — is derived HERE, the single source of truth for the
// loom2v codec, sigmap's provenance table, and the trace manifest the host
// oracle decodes from.
pub struct EthLayoutCell {
pub:
	frame  string
	id     int
	sig    string
	field  string
	offset int
	width  int
	typ    string
}

// eth_bus_of returns the (single, ecucheck-enforced) kind = "eth" bus, or ''.
pub fn eth_bus_of(doc toml.Doc) string {
	if bv := doc.value_opt('bus') {
		for bname, bcfg in bv.as_map() {
			if str_of(bcfg.as_map(), 'kind') == 'eth' {
				return bname
			}
		}
	}
	return ''
}

// eth_layouts derives every eth frame's canonical payload layout. Invalid
// pieces (unknown signals, non-scalar fields) contribute nothing — the
// validator reports them; this derivation serves the already-valid config.
pub fn eth_layouts(doc toml.Doc) []EthLayoutCell {
	eth := eth_bus_of(doc)
	mut out := []EthLayoutCell{}
	if eth == '' {
		return out
	}
	mut sig_fields := map[string]map[string]string{}
	for sg in toml_arr(doc, 'signal') {
		sm := sg.as_map()
		mut fields := map[string]string{}
		if f := sm['fields'] {
			for fname, ftyp in f.as_map() {
				fields[fname] = ftyp.string()
			}
		}
		sig_fields[str_of(sm, 'name')] = fields.clone()
	}
	for f in toml_arr(doc, 'frame') {
		fm := f.as_map()
		if str_of(fm, 'bus') != eth {
			continue
		}
		fname := str_of(fm, 'name')
		fid := int((fm['id'] or { toml.Any(0) }).int())
		mut off := 0
		for sv in arr_of(fm, 'signals') {
			sname := sv.string()
			if sname !in sig_fields {
				continue
			}
			fields := sig_fields[sname].clone()
			mut fnames := fields.keys()
			fnames.sort()
			for fn_ in fnames {
				w := scalar_width(fields[fn_])
				if w == 0 {
					continue
				}
				out << EthLayoutCell{
					frame:  fname
					id:     fid
					sig:    sname
					field:  fn_
					offset: off
					width:  w
					typ:    fields[fn_]
				}
				off += w
			}
		}
	}
	return out
}

// validate_someip checks the eth bus + [someip] + eth [[frame]] rules
// (docs/someip.md): one eth bus per image, the [someip]/eth-traffic pairing,
// event-class ids unique across bindings, the signals list with its canonical
// fixed-width layout, one direction per frame, and the shared 64-byte PDU
// bound (comm.com max_pdu — the codec/router path is sized for it).
fn validate_someip(doc toml.Doc, part_names map[string]bool, thread_part map[string]string, bus_names map[string]bool) []string {
	mut errs := []string{}
	mut eth_buses := []string{}
	if bv := doc.value_opt('bus') {
		for bname, btbl in bv.as_map() {
			kind := str_of(btbl.as_map(), 'kind')
			if kind !in ['', 'can', 'eth'] {
				errs << 'bus "${bname}" kind "${kind}" is invalid (can | eth)'
			} else if kind == 'eth' {
				eth_buses << bname
			}
		}
	}
	if eth_buses.len > 1 {
		errs << '${eth_buses.len} eth buses declared (${eth_buses.join(', ')}) — one eth bus per image (docs/someip.md; a keyed [someip.<bus>] is the later generalisation)'
	}
	eth := if eth_buses.len == 1 { eth_buses[0] } else { '' }

	// signals by name, for direction/shape checks
	mut sig_from := map[string]string{}
	mut sig_to := map[string]string{}
	mut sig_size := map[string]int{}
	mut sig_mem := map[string]int{}
	mut sig_badfield := map[string]string{}
	for sg in toml_arr(doc, 'signal') {
		sm := sg.as_map()
		sname := str_of(sm, 'name')
		sig_from[sname] = str_of(sm, 'from')
		sig_to[sname] = str_of(sm, 'to')
		if f := sm['fields'] {
			mut size := 0
			// the IN-MEMORY struct size too (natural alignment, declaration
			// order): the handlers publish sig.<Name> through IOC, whose slot
			// is 64 bytes (IOC_MAX, osal_native.c) — a signal can fit the wire
			// yet overflow the slot after C/V padding
			mut msize := 0
			mut maxal := 1
			for fname, ftyp in f.as_map() {
				w := scalar_width(ftyp.string())
				if w == 0 {
					sig_badfield[sname] = '${fname} "${ftyp.string()}"'
					continue
				}
				size += w
				if w > maxal {
					maxal = w
				}
				msize = (msize + w - 1) / w * w + w
			}
			msize = (msize + maxal - 1) / maxal * maxal
			sig_size[sname] = size
			sig_mem[sname] = msize
		}
	}

	// FB reads/writes fan-in per signal (the io validator's pattern): the eth
	// channel topology must stay SPSC — the bridge owns one side, so extra or
	// wrong-side or wrong-partition accessors are config errors, not surprises
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

	mut seen_ids := map[i64]string{} // event id -> frame (unique across bindings)
	mut sig_frame := map[string]string{} // signal -> frame (a signal rides one frame)
	mut n_eth_frames := 0
	for f in toml_arr(doc, 'frame') {
		fm := f.as_map()
		if eth == '' || str_of(fm, 'bus') != eth {
			// on a CAN bus the eth-frame keys are silently ignored by loom2v
			// (identity/layout come from the DBC) — reject them loud instead
			if 'id' in fm || 'signals' in fm {
				errs << 'frame "${str_of(fm, 'name')}" is not on an eth bus but declares eth-frame keys (`id`/`signals`) — CAN identity and layout come from the DBC'
			}
			continue
		}
		n_eth_frames++
		fname := str_of(fm, 'name')
		// the name reaches generated identifiers AND unquoted manifest CSV rows
		if !ident_ok(fname) {
			errs << 'eth frame name "${fname}" is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*) — it becomes generated code names and manifest CSV cells'
			continue
		}
		if v := fm['id'] {
			if v is i64 {
				if v < 0x8000 || v > 0xFFFF {
					errs << 'eth frame "${fname}" id 0x${v.hex()} is not an event id — signal frames are events (bit 15 set: 0x8000..0xFFFF); methods are module-bound and arrive with the RPC phase'
				} else if v in seen_ids {
					errs << 'eth frame "${fname}" reuses event id 0x${v.hex()} (already bound by "${seen_ids[v]}") — ids are unique across all bindings'
				} else {
					seen_ids[v] = fname
				}
			} else {
				errs << 'eth frame "${fname}" id must be an integer event id'
			}
		} else {
			errs << 'eth frame "${fname}" is missing `id` (the SOME/IP event id, 0x8000..0xFFFF)'
		}
		sigs := arr_of(fm, 'signals')
		if sigs.len == 0 {
			errs << 'eth frame "${fname}" needs a non-empty `signals` list — membership and the derived layout come from it (docs/someip.md; module frames bind through their module block instead)'
			continue
		}
		mut ntx := 0
		mut nrx := 0
		mut size := 0
		for s in sigs {
			sname := s.string()
			if sname !in sig_from {
				errs << 'eth frame "${fname}" lists unknown signal "${sname}"'
				continue
			}
			if sname in sig_frame {
				errs << 'signal "${sname}" rides two eth frames ("${sig_frame[sname]}" and "${fname}") — a signal rides exactly one frame'
			} else {
				sig_frame[sname] = fname
			}
			if sig_from[sname] == eth && sig_to[sname] == eth {
				errs << 'signal "${sname}" names eth bus "${eth}" on BOTH sides — a signal has the bus on exactly one side (the bridge cannot hold both channel roles: SPSC)'
			} else if sig_to[sname] == eth {
				ntx++
				// SPSC ownership, tx: the app side produces, the bridge consumes.
				mut other := sig_from[sname]
				if other in bus_names {
					errs << 'signal "${sname}": the non-eth side is bus "${other}" — an eth signal passes through the application, never bus-to-bus'
				} else {
					if other in thread_part {
						other = thread_part[other]
					} else if other !in part_names {
						errs << 'signal "${sname}": endpoint "${other}" is not a declared partition or thread'
						other = ''
					}
					if writers[sname] or { 0 } > 1 {
						errs << 'eth tx signal "${sname}" has ${writers[sname]} writing handlers — dual producers break SPSC'
					} else if writers[sname] or { 0 } == 1 && other != ''
						&& writer_part[sname] != other {
						errs << 'eth tx signal "${sname}" is written from partition "${writer_part[sname]}" but declares endpoint "${other}" — the writer must live in the declared partition'
					}
					if readers[sname] or { 0 } > 0 {
						errs << 'eth tx signal "${sname}" appears in a handler\'s reads — the bridge owns that channel side (single-reader transport)'
					}
				}
			} else if sig_from[sname] == eth {
				nrx++
				// SPSC ownership, rx: the bridge produces, the app side consumes.
				mut other := sig_to[sname]
				if other in bus_names {
					errs << 'signal "${sname}": the non-eth side is bus "${other}" — an eth signal passes through the application, never bus-to-bus'
				} else {
					if other in thread_part {
						other = thread_part[other]
					} else if other !in part_names {
						errs << 'signal "${sname}": endpoint "${other}" is not a declared partition or thread'
						other = ''
					}
					if readers[sname] or { 0 } > 1 {
						errs << 'eth rx signal "${sname}" has ${readers[sname]} reading handlers — the channel is single-reader'
					} else if readers[sname] or { 0 } == 1 && other != ''
						&& reader_part[sname] != other {
						errs << 'eth rx signal "${sname}" is read from partition "${reader_part[sname]}" but declares endpoint "${other}" — the reader must live in the declared partition'
					}
					if writers[sname] or { 0 } > 0 {
						errs << 'eth rx signal "${sname}" appears in a handler\'s writes — the bridge is its only producer'
					}
				}
			} else {
				errs << 'eth frame "${fname}" lists signal "${sname}" which does not name bus "${eth}" on either side'
			}
			if bad := sig_badfield[sname] {
				errs << 'signal "${sname}" field ${bad} is not a fixed-width scalar (bool, u8..u64, i8..i64, f32/f64) — the derived eth layout has no meaning for it'
			}
			if sig_mem[sname] or { 0 } > 64 {
				errs << 'signal "${sname}" in-memory struct is ${sig_mem[sname]} bytes after alignment — it exceeds the 64-byte IOC slot (IOC_MAX, osal_native.c); reorder or shrink its fields'
			}
			size += sig_size[sname] or { 0 }
		}
		if ntx > 0 && nrx > 0 {
			errs << 'eth frame "${fname}" mixes tx and rx signals — one direction per frame (a mixed frame would make the bridge a second writer on an SPSC channel)'
		}
		// the bridge derives direction from the signal endpoints — a behavior
		// block for the OTHER direction is silently ignored (a tx mode that
		// never publishes, an rx deadline never enforced): reject it
		if nrx > 0 && ntx == 0 && 'tx' in fm {
			errs << 'eth frame "${fname}" is rx (signals from the bus) but declares a tx block — the mode would silently never publish'
		}
		if ntx > 0 && nrx == 0 && 'rx' in fm {
			errs << 'eth frame "${fname}" is tx (signals to the bus) but declares an rx block — the deadline would silently never be enforced'
		}
		// SecOC has no eth story yet: the derived payload reserves no
		// freshness/MAC bytes and no appended auth layout is defined
		if 'secoc' in fm {
			errs << 'eth frame "${fname}" declares secoc — SecOC on eth is not defined (no reserved freshness/MAC bytes in the derived layout); an appended auth layout is its own rung'
		}
		// the E2E loss protection is an APPENDED trailer on eth (docs/someip.md):
		// the counter byte sits at the derived layout size, the CRC after it —
		// comm/e2e.protect writes THROUGH the configured positions, so anything
		// else would overwrite signal bytes, not append. The trailer counts
		// toward the bound.
		if ev := fm['e2e'] {
			evm := ev.as_map()
			cpos := (evm['counter_pos'] or { toml.Any(i64(-1)) }).i64()
			crc := (evm['crc_pos'] or { toml.Any(i64(-1)) }).i64()
			if cpos != size || crc != size + 1 {
				errs << 'eth frame "${fname}" E2E is an appended trailer: counter_pos must equal the derived layout size (${size}) and crc_pos ${
					size + 1} (got ${cpos}/${crc}) — other positions overwrite signal bytes'
			}
			// the generated protect call narrows data_id to u16 — distinct
			// over-wide ids would silently alias one E2E identity. Type-check
			// too: .i64() coerces a string to 0, which would pass the range
			// when loom2v runs without ecucheck's schema pass.
			if dv := evm['data_id'] {
				if dv !is i64 || dv.i64() < 0 || dv.i64() > 0xFFFF {
					errs << 'eth frame "${fname}" E2E data_id must be an integer fitting 16 bits (0..0xFFFF)'
				}
			} else {
				errs << 'eth frame "${fname}" E2E data_id must be an integer fitting 16 bits (0..0xFFFF)'
			}
			size += 2
		}
		if size > 64 {
			errs << 'eth frame "${fname}" derived payload is ${size} bytes (E2E trailer included) — the shared PDU bound is 64 (comm.com max_pdu); a wider eth PDU is its own rung, not a silent relaxation'
		}
	}
	// the reverse membership check: an eth-bound signal outside every frame
	// would be a phantom endpoint — no layout, no route, silently dead
	if eth != '' {
		for sname, from in sig_from {
			if (from == eth || sig_to[sname] == eth) && sname !in sig_frame {
				errs << 'signal "${sname}" is bound to eth bus "${eth}" but rides no eth frame — an unpublished input or a never-transmitted output'
			}
		}
	}

	// ENABLED modules bound to the eth bus count as eth traffic for the pairing
	// rule — but only once at least one endpoint id is validly bound (a block
	// that names the bus with no endpoints has nothing riding it). Their ids
	// join the shared event-id space (unique across ALL bindings,
	// docs/someip.md). Defaults mirror loom2v: telemetry is off unless enabled,
	// the others on unless disabled; trace and shell INHERIT [telemetry].bus
	// when they omit their own (the generators do). NM on eth is its own phase
	// (comm/nm_udp), and the eth shell is the RPC phase (P3: method-form + the
	// access gate) — both rejected rather than half-bound as events.
	mod_id_keys := {
		'trace':     ['cmd', 'rsp', 'record']
		'telemetry': ['id', 'detail_id']
	}
	mut telem_bus := ''
	if tv := doc.value_opt('telemetry') {
		telem_bus = str_of(tv.as_map(), 'bus')
	}
	mut mod_on_eth := false
	for blk in ['trace', 'telemetry', 'shell', 'nm'] {
		bt := doc.value_opt(blk) or { continue }
		bm := bt.as_map()
		def_on := blk != 'telemetry'
		on := (bm['enabled'] or { toml.Any(def_on) }).bool()
		mut mbus := str_of(bm, 'bus')
		if 'bus' !in bm && blk in ['trace', 'shell'] {
			mbus = telem_bus
		}
		if eth == '' || !on || mbus != eth {
			continue
		}
		if blk == 'nm' {
			errs << '[nm] is bound to eth bus "${eth}" — NM over eth (comm/nm_udp) is its own phase and is not generated; keep NM on a CAN bus'
			continue
		}
		if blk == 'shell' {
			errs << '[shell] is bound to eth bus "${eth}" — the eth shell arrives with the RPC phase (P3: method-form request/response + the access gate, docs/someip.md); keep the shell on a CAN bus'
			continue
		}
		mut bound := 0
		for kk in mod_id_keys[blk] {
			v := bm[kk] or { continue }
			if v is i64 {
				if v < 0x8000 || v > 0xFFFF {
					errs << '[${blk}] ${kk} id 0x${v.hex()} on the eth bus is not an event id (0x8000..0xFFFF)'
				} else if v in seen_ids {
					errs << '[${blk}] ${kk} reuses event id 0x${v.hex()} (already bound by "${seen_ids[v]}") — ids are unique across all bindings'
				} else {
					seen_ids[v] = '[${blk}] ${kk}'
					bound++
				}
			} else {
				errs << '[${blk}] ${kk} on the eth bus must be a literal event id — there is no DBC to resolve a name against'
			}
		}
		// trace's dump_fc selects the ISO-TP block-dump path (comm/trace) —
		// eth has no segmentation, so the adapter cannot honor it
		if blk == 'trace' && 'dump_fc' in bm {
			errs << '[trace] dump_fc is bound on the eth bus — the flow-controlled ISO-TP dump path has no eth counterpart (no segmentation, docs/someip.md); an eth block-transfer layout is its own rung'
		}
		// telemetry always transmits its CpuLoad frame on `id`, and the
		// generator defaults an absent id to 0 — a method-class id that would
		// bypass every check above
		if blk == 'telemetry' && 'id' !in bm {
			errs << '[telemetry] on eth bus "${eth}" needs an explicit `id` (the generator defaults it to 0, outside the event range)'
		}
		if bound == 0 {
			errs << '[${blk}] is bound to eth bus "${eth}" but binds no valid endpoint id — nothing rides the bus (the generator would default ids outside the event range)'
		} else {
			mod_on_eth = true
		}
	}

	// ISO-TP is CAN machinery too: a [[isotp]] connection on the eth bus would
	// emit isotp.Pdu traffic as can.Frame ops — no segmentation path on eth
	if eth != '' {
		for it in toml_arr(doc, 'isotp') {
			itm := it.as_map()
			if str_of(itm, 'bus') == eth {
				errs << '[[isotp]] "${str_of(itm, 'name')}" is bound to eth bus "${eth}" — there is no ISO-TP/segmentation path on eth (docs/someip.md); an eth diagnostic rung is its own phase'
			}
		}
	}

	// raw [[route]] gateways are CAN machinery (DBC-resolved, can.Channel both
	// ends) — a route touching the eth bus would emit a raw-CAN gateway for a
	// SOME/IP endpoint; a CAN↔SOME/IP gateway is its own explicit rung
	if eth != '' {
		for r in toml_arr(doc, 'route') {
			rm := r.as_map()
			mut fbus := ''
			mut tbus := ''
			if fv := rm['from'] {
				fbus = str_of(fv.as_map(), 'bus')
			}
			if tv := rm['to'] {
				tbus = str_of(tv.as_map(), 'bus')
			}
			if fbus == eth || tbus == eth {
				errs << 'a [[route]] touches eth bus "${eth}" — raw-frame routing is CAN machinery; a CAN↔SOME/IP gateway is its own rung, not an implicit route'
			}
		}
	}

	if sp := doc.value_opt('someip') {
		spm := sp.as_map()
		if eth == '' {
			errs << '[someip] declared but no bus has kind = "eth" — half-configured transports fail loud'
		} else {
			if str_of(spm, 'bus') != eth {
				errs << '[someip] bus "${str_of(spm, 'bus')}" is not the eth bus ("${eth}")'
			}
			if n_eth_frames == 0 && !mod_on_eth {
				errs << '[someip] declared but nothing rides bus "${eth}" — no eth [[frame]] and no module bound to it'
			}
		}
		if v := spm['service'] {
			if v !is i64 || v.i64() < 0 || v.i64() > 0xFFFF {
				errs << '[someip] service must fit 16 bits (0..0xFFFF)'
			}
		}
		if v := spm['version'] {
			if v !is i64 || v.i64() < 0 || v.i64() > 0xFF {
				errs << '[someip] version must fit 8 bits (0..255) — the interface version byte in every header'
			}
		}
		if v := spm['port'] {
			if v !is i64 || v.i64() < 1 || v.i64() > 65535 {
				errs << '[someip] port must be 1..65535'
			}
		}
		if 'peer' in spm && !peer_ok(str_of(spm, 'peer')) {
			errs << '[someip] peer "${str_of(spm, 'peer')}" must be an address:port pair with a valid port (1..65535)'
		}
	} else if n_eth_frames > 0 || mod_on_eth {
		errs << 'traffic rides eth bus "${eth}" but there is no [someip] block (the service identity + static endpoints)'
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
			if fh !is i64 || (fh as i64) <= 0 || (fh as i64) > 10_000_000 {
				// 10 MHz PWM ceiling: also keeps freq_hz inside V int / u32 before the
				// generator narrows it (a >2^31 value would wrap — codex emb#152)
				errs << 'io.pwm "${name}" needs a freq_hz in 1..10000000 (the carrier; a zero divisor is not a timer, and a huge value wraps the 32-bit codegen)'
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
			if kind == 'adc' {
				if dv := pm['default'] {
					ft := sig_ftype[name]
					maxv := if ft == 'u16' { i64(65535) } else { i64(4294967295) }
					if dv !is i64 || (dv as i64) < 0 || (dv as i64) > maxv {
						errs << 'io.adc "${name}" default must be an integer in 0..${maxv} (the bound ${ft} range) — a negative or oversized default overflows the count'
					}
				}
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
	// the H7 ADC regular sequence holds at most 16 ranks — one per adc point
	mut n_adc := 0
	for pi2, _ in points {
		if point_kind[pi2] == 'adc' {
			n_adc++
		}
	}
	if n_adc > 16 {
		errs << 'io.adc: ${n_adc} analog points exceed the 16-channel ADC scan sequence — split across a second ADC (a later phase) or reduce points'
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
