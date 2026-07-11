// loom2v — BUILD-TIME tool. From ecu.toml (+ the DBC) it generates, for one
// example:
//   * sig/signals_gen.v   — `module sig`:   signal value types (from .fields)
//   * ports/ports_gen.v   — `module ports`: per-FB In/Out structs (imports sig)
//   * gen/loom_gen.v      — `module gen`:   state + snapshot glue + entries,
//                                           the generated COM bus bridge, run()
//
// An endpoint is a PARTITION or a BUS. That makes external vs internal explicit:
//   * endpoint is a bus  -> EXTERNAL: COM-encoded via the DBC; the bus bridge
//                           decodes rx signals -> IOC, encodes tx signals <- IOC
//   * both partitions    -> INTERNAL: from == to -> local cell, else IOC channel
//
//   v run tools/loom2v/gen.v <ecu.toml> <bus.dbc> <signals_out> <ports_out> <glue_out>
// (run from a freestanding example with its own v.mod, so module names are short)
module main

import os
import toml
import tools.candb
import tools.ecumodel

struct SigInfo {
mut:
	name      string // the signal name (so a bare SigInfo still knows its own name)
	transport string
	from      string
	to        string
	local     bool
	external  bool   // an endpoint is a bus
	bus       string // the bus name (if external)
	rx        bool   // external && bus is the `from` endpoint (bus -> app)
	val_field string // the signal's value field (the non-"valid" field)
	val_type  string // its V type
	has_valid bool   // a `valid` field is present
	dbc_msg   string // snake(DBC message name) carrying this signal (if external)
	dbc_id    int    // the DBC message's CAN id (if external) — resolved once at parse time
	dbc_dlc   int    // the DBC message's DLC (if external)
	dbc_ext   bool   // the DBC message is an extended (29-bit) frame (EFF flag) — id may be stripped
	dbc_trivial bool // the DBC signal is a plain unsigned LE 32-bit value at bit 0 (factor 1, offset 0)
	fields    []SigField // the signal's fields in declaration order (for the `sig` struct emit)
}

// SigField is one field of a signal's payload struct (name + V type), in declaration order.
struct SigField {
	name string
	typ  string
}

// IsotpConn is one [[isotp]] diagnostic connection on a bus.
struct IsotpConn {
	name  string
	bus   string
	rx_id int
	tx_id int
	bs    int
	stmin int
}

// DidCfg is one [[did]]: constant bytes, a writable RAM cell, and/or a live signal.
struct DidCfg {
	id       int
	bytes    []u8
	writable bool
	signal   string
}

// Route is one [[route]]: forward a raw frame from one bus to another (gateway),
// without decoding it to signals. to_id == 0 means keep the source id.
struct Route {
mut:
	from_bus   string
	from_frame string
	from_id    int
	to_bus     string
	to_id      int
}

// TargetCfg is the parsed [target] block. kind selects the on-target emitter: 'baremetal' =
// single-core inline superloop (P3c-0); 'threadx' = the preemptive-RTOS target (P3c-1).
struct TargetCfg {
mut:
	on      bool
	threadx bool
	tick_us u64 = 1000
}

// TelemetryCfg is the parsed [telemetry] block (the scratch slots + iface are derived later).
struct TelemetryCfg {
mut:
	on        bool
	bus       string
	id        u32
	detail_id u32 // optional LoadDetail frame (multi-window + overruns)
	period_us u64 = 1_000_000
}

// FrameCfg is the parsed per-PDU COM behaviour ([[frame]]), keyed by snake(DBC message name):
// tx mode/timing, rx deadline, E2E, SecOC. Absent -> defaults (tx cyclic@100ms, no rx t/o).
struct FrameCfg {
mut:
	tx_mode       map[string]string
	tx_cycle_us   map[string]int
	tx_min_us     map[string]int
	rx_timeout_us map[string]int
	e2e_on        map[string]bool
	e2e_id        map[string]int
	e2e_crc       map[string]int
	e2e_ctr       map[string]int
	secoc_on      map[string]bool
	secoc_id      map[string]int
	secoc_fresh   map[string]int
	secoc_mac     map[string]int
	secoc_maclen  map[string]int
	secoc_key     map[string][]u8
}

// parse_signals parses [[signal]] into the model: sig_of (with each signal's fields in
// declaration order), sig_names, and has_external. External signals are then resolved against
// bus.dbc (message id/dlc/ext/trivial). Value field = the single non-"valid" field.
fn parse_signals(doc toml.Doc, dbc string, buses map[string]bool) (map[string]SigInfo, []string, bool) {
	mut sig_of := map[string]SigInfo{}
	mut sig_names := []string{}
	mut has_external := false
	for s in ecumodel.toml_arr(doc, 'signal') {
		m := s.as_map()
		name := (m['name'] or { toml.Any('') }).string()
		from := (m['from'] or { toml.Any('') }).string()
		to := (m['to'] or { toml.Any('') }).string()

		from_bus := from in buses
		to_bus := to in buses
		external := from_bus || to_bus
		if external {
			has_external = true
		}

		fields := (m['fields'] or { toml.Any(map[string]toml.Any{}) }).as_map()
		if fields.len == 0 {
			panic('ecu.toml: signal "${name}" needs `fields` (e.g. fields = { kph = "u16" })')
		}
		mut val_field := ''
		mut val_type := ''
		mut has_valid := false
		mut sfields := []SigField{}
		for fname, ftype in fields {
			sfields << SigField{
				name: fname
				typ:  ftype.string()
			}
			if fname == 'valid' {
				has_valid = true
			} else if val_field == '' {
				val_field = fname
				val_type = ftype.string()
			}
		}

		sig_of[name] = SigInfo{
			name:      name
			transport: (m['transport'] or { toml.Any('double') }).string()
			from:      from
			to:        to
			local:     from == to
			external:  external
			bus:       if from_bus { from } else { to }
			rx:        from_bus
			val_field: val_field
			val_type:  val_type
			has_valid: has_valid
			fields:    sfields
		}
		sig_names << name
	}
	// Map each external signal to its DBC message (so the bridge can name the generated codec
	// fns / id / dlc). External signals must be in the DBC.
	if has_external {
		db := candb.load_dbc_file(dbc) or {
			panic('external signals need a DBC: load ${dbc}: ${err}')
		}
		for sname in sig_names {
			mut si := sig_of[sname] or { continue }
			if !si.external {
				continue
			}
			si.dbc_msg = dbc_message_of(db, sname) or {
				panic('signal "${sname}" has a bus endpoint but is not in ${os.file_name(dbc)}')
			}
			si.dbc_id = dbc_id_of(db, si.dbc_msg) or { 0 }
			si.dbc_dlc = dbc_dlc_of(db, si.dbc_msg) or { 8 }
			si.dbc_ext = dbc_ext_of(db, si.dbc_msg) or { false }
			si.dbc_trivial = dbc_signal_trivial(db, sname) or { false }
			sig_of[sname] = si
		}
	}
	return sig_of, sig_names, has_external
}

// emit_signals generates the `sig` module — one struct per signal, fields in declaration order —
// from the model. (Emit is now separate from the parse that built sig_of.)
fn emit_signals(sig_of map[string]SigInfo, sig_names []string, ecu string) []string {
	mut signals := []string{}
	signals << '// Code generated by tools/loom2v from ${os.file_name(ecu)} — DO NOT EDIT.'
	signals << 'module sig'
	for name in sig_names {
		si := sig_of[name] or { continue }
		signals << ''
		signals << 'pub struct ${name} {'
		signals << 'pub mut:'
		for f in si.fields {
			signals << '\t${f.name} ${f.typ}'
		}
		signals << '}'
	}
	return signals
}

// PartMap is the partition/thread/fb topology (the model). An fb maps to a globally-unique
// THREAD; its partition is derived from that thread, so by_part groups fbs by derived partition.
struct PartMap {
mut:
	core_of     map[string]int         // partition -> core
	threads_of  map[string][]string    // partition -> its thread names, declaration order
	thread_part map[string]string      // thread -> partition
	thread_prio map[string]int         // thread -> [[partition.thread]].priority (default 10)
	by_part     map[string][]toml.Any  // partition -> its fb config objects
	fb_thread   map[string]string      // fb -> its thread
}

// parse_buses returns the declared buses (endpoint names that mean "external / on the wire")
// and each bus's core.
// parse_routes parses [[route]] (raw-PDU gateway: forward a frame bus->bus, no decode) and
// resolves each from-frame to its DBC id (routes need a DBC).
fn parse_routes(doc toml.Doc, dbc string) []Route {
	mut routes := []Route{}
	for r in ecumodel.toml_arr(doc, 'route') {
		m := r.as_map()
		fm := (m['from'] or { toml.Any('') }).as_map()
		tm := (m['to'] or { toml.Any('') }).as_map()
		fb := (fm['bus'] or { toml.Any('') }).string()
		if fb == '' {
			continue
		}
		routes << Route{
			from_bus:   fb
			from_frame: (fm['frame'] or { toml.Any('') }).string()
			to_bus:     (tm['bus'] or { toml.Any('') }).string()
			to_id:      int((tm['id'] or { toml.Any(0) }).int())
		}
	}
	if routes.len > 0 {
		db := candb.load_dbc_file(dbc) or { panic('routes need a DBC: load ${dbc}: ${err}') }
		for i, r in routes {
			id := dbc_id_of(db, snake(r.from_frame)) or {
				panic('route: frame "${r.from_frame}" is not a message in ${os.file_name(dbc)}')
			}
			routes[i].from_id = id
			if routes[i].to_id == 0 {
				routes[i].to_id = id // keep the source id unless remapped
			}
		}
	}
	return routes
}

// parse_isotp parses [[isotp]] diagnostic connections.
fn parse_isotp(doc toml.Doc) []IsotpConn {
	mut isotp_conns := []IsotpConn{}
	for c in ecumodel.toml_arr(doc, 'isotp') {
		m := c.as_map()
		name := (m['name'] or { toml.Any('') }).string()
		if name == '' {
			continue // absent [[isotp]] section can yield a phantom empty entry
		}
		isotp_conns << IsotpConn{
			name:  name
			bus:   (m['bus'] or { toml.Any('') }).string()
			rx_id: int((m['rx_id'] or { toml.Any(0) }).int())
			tx_id: int((m['tx_id'] or { toml.Any(0) }).int())
			bs:    int((m['bs'] or { toml.Any(0) }).int())
			stmin: int((m['stmin_ms'] or { toml.Any(0) }).int())
		}
	}
	return isotp_conns
}

// parse_dids parses [[did]] UDS Data Identifiers: constant (ascii/bytes), writable RAM, or live signal.
fn parse_dids(doc toml.Doc) []DidCfg {
	mut dids := []DidCfg{}
	for d in ecumodel.toml_arr(doc, 'did') {
		m := d.as_map()
		id := int((m['id'] or { toml.Any(0) }).int())
		if id == 0 {
			continue
		}
		mut bytes := []u8{}
		if 'ascii' in m {
			for ch in (m['ascii'] or { toml.Any('') }).string() {
				bytes << u8(ch)
			}
		} else if 'bytes' in m {
			bytes = parse_hex((m['bytes'] or { toml.Any('') }).string())
		}
		dids << DidCfg{
			id:       id
			bytes:    bytes
			writable: (m['writable'] or { toml.Any(false) }).bool()
			signal:   (m['signal'] or { toml.Any('') }).string()
		}
	}
	return dids
}

fn parse_buses(doc toml.Doc) (map[string]bool, map[string]int) {
	mut buses := map[string]bool{}
	mut bus_core := map[string]int{}
	for bname, bcfg in doc.value('bus').as_map() {
		buses[bname] = true
		bus_core[bname] = int((bcfg.as_map()['core'] or { toml.Any(0) }).int())
	}
	return buses, bus_core
}

fn parse_partitions(doc toml.Doc) PartMap {
	mut p := PartMap{}
	for pt in ecumodel.toml_arr(doc, 'partition') {
		m := pt.as_map()
		pname := (m['name'] or { toml.Any('') }).string()
		p.core_of[pname] = int((m['core'] or { toml.Any(0) }).int())
		for t in (m['thread'] or { toml.Any([]toml.Any{}) }).array() {
			tm := t.as_map()
			tname := (tm['name'] or { toml.Any('') }).string()
			p.thread_part[tname] = pname
			p.threads_of[pname] << tname
			p.thread_prio[tname] = int((tm['priority'] or { toml.Any(10) }).int())
		}
	}
	for c in ecumodel.toml_arr(doc, 'fb') {
		cm := c.as_map()
		fbname := (cm['name'] or { toml.Any('') }).string()
		thr := (cm['thread'] or { toml.Any('') }).string()
		p.by_part[p.thread_part[thr]] << c
		p.fb_thread[fbname] = thr
	}
	// threads sorted by PRIORITY within each partition (highest first = lowest number): thread
	// creation order, manifest thread ids, and the trace recorder's first-sight ids all follow
	// priority at kernel entry, so keeping one canonical order makes them agree by construction.
	for pname, _ in p.threads_of {
		mut ts := p.threads_of[pname].clone()
		for i in 1 .. ts.len {
			mut j := i
			for j > 0 && (p.thread_prio[ts[j]] or { 10 }) < (p.thread_prio[ts[j - 1]] or { 10 }) {
				ts[j], ts[j - 1] = ts[j - 1], ts[j]
				j--
			}
		}
		p.threads_of[pname] = ts
	}

	return p
}

fn parse_frames(doc toml.Doc) FrameCfg {
	mut f := FrameCfg{}
	for fr in ecumodel.toml_arr(doc, 'frame') {
		fm := fr.as_map()
		fk := snake((fm['name'] or { toml.Any('') }).string())
		if 'tx' in fm {
			txm := (fm['tx'] or { toml.Any('') }).as_map()
			f.tx_mode[fk] = (txm['mode'] or { toml.Any('cyclic') }).string()
			f.tx_cycle_us[fk] = int((txm['cycle_ms'] or { toml.Any(0) }).int()) * 1000
			f.tx_min_us[fk] = int((txm['min_delay_ms'] or { toml.Any(0) }).int()) * 1000
		}
		if 'rx' in fm {
			rxm := (fm['rx'] or { toml.Any('') }).as_map()
			f.rx_timeout_us[fk] = int((rxm['timeout_ms'] or { toml.Any(0) }).int()) * 1000
		}
		if 'e2e' in fm {
			em := (fm['e2e'] or { toml.Any('') }).as_map()
			f.e2e_on[fk] = true
			f.e2e_id[fk] = int((em['data_id'] or { toml.Any(0) }).int())
			f.e2e_crc[fk] = int((em['crc_pos'] or { toml.Any(0) }).int())
			f.e2e_ctr[fk] = int((em['counter_pos'] or { toml.Any(0) }).int())
		}
		if 'secoc' in fm {
			sm := (fm['secoc'] or { toml.Any('') }).as_map()
			f.secoc_on[fk] = true
			f.secoc_id[fk] = int((sm['data_id'] or { toml.Any(0) }).int())
			f.secoc_fresh[fk] = int((sm['fresh_pos'] or { toml.Any(0) }).int())
			f.secoc_mac[fk] = int((sm['mac_pos'] or { toml.Any(0) }).int())
			f.secoc_maclen[fk] = int((sm['mac_len'] or { toml.Any(4) }).int())
			f.secoc_key[fk] = parse_hex((sm['key'] or { toml.Any('') }).string())
		}
	}
	return f
}

fn parse_telemetry(doc toml.Doc) TelemetryCfg {
	mut t := TelemetryCfg{}
	if tcfg := doc.value_opt('telemetry') {
		tm := tcfg.as_map()
		t.on = (tm['enabled'] or { toml.Any(false) }).bool()
		t.bus = (tm['bus'] or { toml.Any('') }).string()
		t.id = u32((tm['id'] or { toml.Any(0) }).int())
		t.detail_id = u32((tm['detail_id'] or { toml.Any(0) }).int())
		if pms := tm['period_ms'] {
			t.period_us = u64(pms.int()) * 1000
		}
	}
	return t
}

fn parse_target(doc toml.Doc) TargetCfg {
	mut t := TargetCfg{}
	if tgt := doc.value_opt('target') {
		tm := tgt.as_map()
		kind := (tm['kind'] or { toml.Any('') }).string()
		t.threadx = kind == 'threadx'
		t.on = kind == 'baremetal' || t.threadx
		if tms := tm['tick_ms'] {
			t.tick_us = u64(tms.int()) * 1000
		}
	}
	return t
}

// Model is the parsed ecu.toml + bus.dbc — everything the emitters need, with no toml.Any left.
// build_model is the single parse pass; the emit code (still in main for now) reads from it.
struct Model {
	buses        map[string]bool
	bus_core     map[string]int
	sig_of       map[string]SigInfo
	sig_names    []string
	has_external bool
	frames       FrameCfg
	routes       []Route
	isotp_conns  []IsotpConn
	dids         []DidCfg
	part         PartMap
	telem        TelemetryCfg
	target       TargetCfg
	trace        TraceCfg
}

fn build_model(doc toml.Doc, dbc string) Model {
	buses, bus_core := parse_buses(doc)
	sig_of, sig_names, has_external := parse_signals(doc, dbc, buses)
	return Model{
		buses:        buses
		bus_core:     bus_core
		sig_of:       sig_of
		sig_names:    sig_names
		has_external: has_external
		frames:       parse_frames(doc)
		routes:       parse_routes(doc, dbc)
		isotp_conns:  parse_isotp(doc)
		dids:         parse_dids(doc)
		part:         parse_partitions(doc)
		telem:        parse_telemetry(doc)
		target:       parse_target(doc)
		trace:        parse_trace(doc, dbc)
	}
}

// Producer is a platform capability that lives on a bus — telemetry and trace today, NM / COM-tx
// tomorrow. The generator iterates producers so the SHARED emitters (the partition loop, each
// run-model, the imports, the manifest) never name a specific capability: adding one is implementing
// this interface, not threading a fresh set of flags/params through every emitter. Hooks are filled
// in phase by phase as the producer redesign lands; each returns the emit fragment for one injection
// point, or an empty slice when that producer contributes nothing there.
// BusCtx is the run-model's scope + data-access contract, handed to each producer's bus_tick. The
// producer owns the frame-build/send LOGIC; the run-model owns HOW to read the data and which local
// names are free (its loop already declares f/rf/pf etc., so a producer must be told a collision-free
// frame/loop name). This is what lets one bus_tick reproduce the bare-metal / ThreadX / inline loops
// byte-for-byte — the genuine differences (load accessor, tx_ready gate, timebase) live here, not in
// copy-pasted blocks. now = the loop's current-time expr; period = the deadline expr (a var name or an
// already-evaluated literal); gate = a '&& ch.tx_ready()' suffix or ''; load/det_lines = the accessor
// lines; frame/detframe/idx = collision-free local names for this run-model's scope.
struct BusCtx {
	telem_active bool
	lead         []string // optional leading comment line(s) some run-models emit before the tick
	now          string
	period       string
	gate         string
	load         []string
	det_ovr      string
	det_lines    []string
	frame        string
	detframe     string
	idx          string
}

interface Producer {
	// The partition superloop is one skeleton; each producer injects at four points, keyed by
	// 'p:<partition>' (or 'b:<bus>' for a bridge). preamble runs once before the loop; loop_top and
	// loop_body run each iteration (top = before dispatch, body = after); dispatch OVERRIDES the
	// default plain dispatch when non-empty (only one producer may — the profiling one).
	partition_preamble(part_key string) []string
	partition_loop_top(part_key string) []string
	partition_dispatch(part_key string) []string
	partition_loop_body(part_key string) []string
	// bus_tick is this producer's periodic emission inside a bus-owning run loop (send a frame when
	// due), rendered for the given run-model contract. Empty when the producer isn't active there.
	bus_tick(ctx BusCtx) []string
}

// TelemProducer publishes each partition's Loom load to a scratch cell so the bus owner can ship it
// as a CpuLoad frame (bus_tick), and reads it back on the bus loop. slot maps a partition key
// ('p:app' / 'b:can0') to its scratch cell index; id/detail_id are the CpuLoad / LoadDetail frame ids.
struct TelemProducer {
	on        bool
	slot      map[string]int
	id        u32
	detail_id u32
}

// bus_tick emits the CpuLoad (+ optional LoadDetail) send, gated on the period, using the run-model's
// data accessors and collision-free names from ctx. Byte-identical to the former per-run-model blocks.
fn (t TelemProducer) bus_tick(ctx BusCtx) []string {
	if !ctx.telem_active {
		return []string{}
	}
	mut g := []string{}
	g << ctx.lead
	g << '\t\tif ${ctx.now} - last_telem >= ${ctx.period}${ctx.gate} {'
	g << '\t\t\tlast_telem = ${ctx.now}'
	g << ctx.load
	g << '\t\t\tframe := telem.encode_cpuload(load, 1)'
	g << '\t\t\tmut ${ctx.frame} := can.Frame{'
	g << '\t\t\t\tid:  u32(0x${t.id.hex()})'
	g << '\t\t\t\tlen: 8'
	g << '\t\t\t}'
	g << '\t\t\tfor ${ctx.idx} in 0 .. 8 {'
	g << '\t\t\t\t${ctx.frame}.data[${ctx.idx}] = frame[${ctx.idx}]'
	g << '\t\t\t}'
	g << '\t\t\tch.send(${ctx.frame})'
	if t.detail_id != 0 {
		g << '\t\t\tovr := ${ctx.det_ovr}'
		g << ctx.det_lines
		g << '\t\t\tlast_overruns = ovr'
		g << '\t\t\tmut ${ctx.detframe} := can.Frame{'
		g << '\t\t\t\tid:  u32(0x${t.detail_id.hex()})'
		g << '\t\t\t\tlen: 8'
		g << '\t\t\t}'
		g << '\t\t\tfor ${ctx.idx} in 0 .. 8 {'
		g << '\t\t\t\t${ctx.detframe}.data[${ctx.idx}] = detail[${ctx.idx}]'
		g << '\t\t\t}'
		g << '\t\t\tch.send(${ctx.detframe})'
	}
	g << '\t\t}'
	return g
}

fn (t TelemProducer) partition_preamble(_ string) []string {
	return []string{}
}

fn (t TelemProducer) partition_loop_top(_ string) []string {
	return []string{}
}

fn (t TelemProducer) partition_dispatch(_ string) []string {
	return []string{}
}

fn (t TelemProducer) partition_loop_body(part_key string) []string {
	if t.on && part_key in t.slot {
		return ['\t\tosal.scratch_set(${t.slot[part_key]}, u64(sched.load_permille()))']
	}
	return []string{}
}

// emit_manifest builds the trace-identity CSV (optional arg 6): the tables blobly_net loads to
// resolve an entity_id back to a name. Two CSV tables, ids assigned GLOBALLY + STABLY in
// declaration order (partition -> fb -> handler for fb.handlers; partition -> thread for threads).
// thread_id starts at 1 — id 0 is reserved for idle (THREAD kind). Threads/fb.handlers are the
// only rows: an ISR's id IS its raw vector (no row). Reads the Model; the three derived inputs
// (comm thread, its partition, the bridge buses) come from main's emit-time state.
fn emit_manifest(m Model, doc toml.Doc, ecu string, comm_thread_on bool, single_part string, bridge_bus_list []string) []string {
	mut man := []string{}
	man << '# generated by loom2v from ${os.base(ecu)} — do not edit'
	man << '# fb.handlers: id,partition,core,fb,handler,period_us,thread'
	mut hid := 0
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		for c in m.part.by_part[pname] {
			cm := c.as_map()
			fbname := (cm['name'] or { toml.Any('') }).string()
			thr := m.part.fb_thread[fbname] // the fb's (globally-unique) thread
			for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hm := h.as_map()
				hname := (hm['name'] or { toml.Any('') }).string()
				period_us := int((hm['period_ms'] or { toml.Any(0) }).int()) * 1000
				man << '${hid},${pname},${m.part.core_of[pname]},${fbname},${hname},${period_us},${thr}'
				hid++
			}
		}
	}
	man << '# threads: thread,id,name,core,prio  (id 0 reserved = idle; prio - = no RTOS prio)'
	mut tid := 1
	// ThreadX comm thread (phase 6b-2): AUTO_START at priority 1 — strictly higher than the FB
	// thread and above the still-suspended system timer thread — so at kernel entry it is the
	// FIRST thread the scheduler runs. trace_hooks.c assigns ids by first sight, so the comm
	// thread takes id 1, ahead of the app thread (id 2) and the timer (id 3). Emit it first to
	// match that observed order, else its records are mislabelled / shift the other lanes.
	if comm_thread_on {
		// comm's priority is derived in the target emit (min(app) - 1, or the historical 1 for a
		// single-thread config) — recompute it here so the manifest can show it.
		mut mp := 32
		for _, thrs in m.part.threads_of {
			for thr in thrs {
				pr := m.part.thread_prio[thr] or { 10 }
				if pr < mp {
					mp = pr
				}
			}
		}
		mut nthr := 0
		for _, thrs in m.part.threads_of {
			nthr += thrs.len
		}
		cp := if nthr > 1 { mp - 1 } else { 1 }
		man << 'thread,${tid},comm,${m.part.core_of[single_part] or { 0 }},${cp}'
		tid++
	}
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		for tname in m.part.threads_of[pname] {
			man << 'thread,${tid},${tname},${m.part.core_of[pname]},${m.part.thread_prio[tname] or { 10 }}' // name = the globally-unique thread name
			tid++
		}
	}
	timer_rows := trace_manifest_timer_row(m, tid)
	man << timer_rows
	tid += timer_rows.len
	// Comm threads (P3b): one per bridge bus, AFTER the app threads (matches the gate's comm_tid
	// numbering).
	for bb in bridge_bus_list {
		man << 'thread,${tid},comm_${bb},${m.bus_core[bb] or { 0 }},-' // host threads: no RTOS prio
		tid++
	}
	man << trace_manifest_frames(m)
	return man
}

// emit_partition_telem emits the host CpuLoad tx thread: sum each core's per-partition load from
// the scratch slots and ship it as a CpuLoad frame every period. Host only — the target and
// inline-trace modes send CpuLoad inline from run(). Returns the glue lines, or none when the
// telemetry-tx thread doesn't apply. (slot_core / telem_iface / trace_inline are main's emit-time
// derived state; everything else comes from the Model.)
fn emit_partition_telem(m Model, telem_iface string, slot_core []int, trace_host bool) []string {
	if !(m.telem.on && telem_iface != '' && !m.target.on && !trace_host) {
		return []string{}
	}
	mut ncores := 0
	for sc in slot_core {
		if sc + 1 > ncores {
			ncores = sc + 1
		}
	}
	mut glue := []string{}
	glue << ''
	glue << 'fn partition_telem() {'
	glue << '\tosal.pin_to_core(${m.bus_core[m.telem.bus] or { 0 }})'
	glue << '\tmut c := can.Channel{}'
	glue << "\tif !c.open('${telem_iface}', false) {"
	glue << '\t\treturn'
	glue << '\t}'
	glue << '\tfor {'
	glue << '\t\tmut load := [8]u16{}'
	for cc in 0 .. ncores {
		mut terms := []string{}
		for slot, sc in slot_core {
			if sc == cc {
				terms << 'u16(osal.scratch_get(${slot}))'
			}
		}
		if terms.len > 0 {
			glue << '\t\tload[${cc}] = ${terms.join(' + ')}'
		}
	}
	glue << '\t\tframe := telem.encode_cpuload(load, ${ncores})'
	glue << '\t\tmut f := can.Frame{'
	glue << '\t\t\tid:  u32(0x${m.telem.id.hex()})'
	glue << '\t\t\tlen: 8'
	glue << '\t\t}'
	glue << '\t\tfor i in 0 .. 8 {'
	glue << '\t\t\tf.data[i] = frame[i]'
	glue << '\t\t}'
	glue << '\t\tc.send(f)'
	glue << '\t\tosal.sleep_us(${m.telem.period_us})'
	glue << '\t}'
	glue << '}'
	return glue
}

// emit_bridges emits the host COM bus bridge(s): per external bus, decode rx -> IOC cells and
// encode IOC cells -> tx frames (+ raw routes, ISO-TP, E2E/SecOC). Skipped for the ThreadX
// comm-thread target (comm_thread_on), which owns rx in its own comm_thread_entry. Returns the
// glue lines plus the bus_names / bus_dests the run() emitters need; reads the Model, with the
// derived scratch/thread layout (telem_slot, comm_tid, trace bases) from main's emit-time state.
fn emit_bridges(m Model, comm_thread_on bool, producers []Producer) ([]string, []string, map[string][]string) {
	mut glue := []string{}
	mut bus_names := []string{}
	mut bus_dests := map[string][]string{}
	for bname, _ in m.buses {
		if comm_thread_on {
			continue
		}
		bb := snake(bname)
		mut rx_by_msg := map[string][]string{}
		mut tx_by_msg := map[string][]string{}
		for sname in m.sig_names {
			si := m.sig_of[sname] or { continue }
			if !si.external || si.bus != bname {
				continue
			}
			if si.rx {
				rx_by_msg[si.dbc_msg] << sname
			} else {
				tx_by_msg[si.dbc_msg] << sname
			}
		}
		mut conns := []IsotpConn{}
		for c in m.isotp_conns {
			if c.bus == bname {
				conns << c
			}
		}
		// m.routes that ORIGINATE on this bus, and the distinct destination m.buses
		mut my_routes := []Route{}
		mut dests := []string{}
		for r in m.routes {
			if r.from_bus == bname {
				my_routes << r
				if r.to_bus !in dests {
					dests << r.to_bus
				}
			}
		}
		dests.sort()
		if rx_by_msg.len == 0 && tx_by_msg.len == 0 && conns.len == 0 && my_routes.len == 0 {
			continue
		}
		bus_names << bname
		bus_dests[bname] = dests

		// io fn needs a timestamp to gate tx, monitor rx deadlines, or pace ISO-TP
		mut uses_now := tx_by_msg.len > 0 || conns.len > 0
		for msg, _ in rx_by_msg {
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				uses_now = true
			}
		}

		glue << ''
		glue << 'struct Bridge_${bb}_state {'
		glue << 'mut:'
		glue << '\tchan can.Channel'
		for msg, _ in tx_by_msg {
			glue << '\ttx_${msg}_st com.TxState'
			if m.frames.e2e_on[msg] or { false } {
				glue << '\te2e_tx_${msg} e2e.TxState'
			}
			if m.frames.secoc_on[msg] or { false } {
				glue << '\tsecoc_key_${msg} secoc.Key'
				glue << '\tsecoc_tx_${msg} secoc.TxState'
			}
		}
		for msg, _ in rx_by_msg {
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				glue << '\trx_${msg}_st com.RxState'
			}
			if m.frames.e2e_on[msg] or { false } {
				glue << '\te2e_rx_${msg} e2e.RxState'
			}
			if m.frames.secoc_on[msg] or { false } {
				glue << '\tsecoc_key_${msg} secoc.Key'
				glue << '\tsecoc_rx_${msg} secoc.RxState'
			}
		}
		for c in conns {
			tp := snake(c.name)
			glue << '\ttp_${tp} isotp.Link'
			glue << '\ttp_${tp}_buf [isotp.max_payload]u8'
			glue << '\tuds_${tp} uds.Server'
			glue << '\tuds_${tp}_resp [64]u8'
		}
		for d in dests {
			glue << '\troute_${snake(d)} can.Channel // gateway: forward to ${d}'
		}
		glue << '}'
		glue << ''
		glue << 'fn io_${bb}_10ms(ctx voidptr) {'
		glue << '\tmut st := unsafe { &Bridge_${bb}_state(ctx) }'
		if uses_now {
			glue << '\tnow := osal.now_us()'
		}
		if rx_by_msg.len > 0 || conns.len > 0 || my_routes.len > 0 {
			glue << '\tmut rx := can.Frame{}'
			glue << '\tfor st.chan.recv(mut rx) {'
			for r in my_routes {
				// raw-PDU gateway: forward the frame to another bus, unchanged
				// (optionally remapping the id), without decoding it to signals.
				glue << '\t\tif rx.id == u32(0x${r.from_id.hex()}) {'
				glue << '\t\t\tmut fwd := rx'
				if r.to_id != r.from_id {
					glue << '\t\t\tfwd.id = u32(0x${r.to_id.hex()})'
				}
				glue << '\t\t\tst.route_${snake(r.to_bus)}.send(fwd)'
				glue << '\t\t}'
			}
			for msg, list in rx_by_msg {
				// require the received length to match the PDU DLC — recv copies only
				// the actual bytes into the reused frame, so a short same-id frame
				// would otherwise be decoded over stale trailing bytes.
				glue << '\t\tif rx.id == ${msg}_id && rx.len == ${msg}_dlc {'
				e2e := m.frames.e2e_on[msg] or { false }
				secoc := m.frames.secoc_on[msg] or { false }
				// protected frames are decoded only if the check passes; a bad frame
				// is ignored (the rx deadline then invalidates).
				mut ind := '\t\t\t'
				if secoc {
					glue << '\t\t\tif st.secoc_rx_${msg}.verify(&st.secoc_key_${msg}, &rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.secoc_id[msg] or {
						0
					}).hex()}), ${m.frames.secoc_fresh[msg] or { 0 }}, ${m.frames.secoc_mac[msg] or { 0 }}, ${m.frames.secoc_maclen[msg] or {
						0
					}}).usable() {'
					ind = '\t\t\t\t'
				} else if e2e {
					glue << '\t\t\tif st.e2e_rx_${msg}.check(&rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or {
						0
					}).hex()}), ${m.frames.e2e_crc[msg] or { 0 }}, ${m.frames.e2e_ctr[msg] or { 0 }}).usable() {'
					ind = '\t\t\t\t'
				}
				for sname in list {
					si := m.sig_of[sname] or { continue }
					fld := snake(sname)
					dec := '${si.dbc_msg}_${snake(sname)}_phys(rx.data)'
					valassign := if si.val_type == 'bool' {
						'${si.val_field}: ${dec} != 0.0'
					} else {
						'${si.val_field}: ${si.val_type}(${dec})'
					}
					validassign := if si.has_valid { ', valid: true' } else { '' }
					glue << '${ind}mut ${fld} := sig.${sname}{ ${valassign}${validassign} }'
					glue << '${ind}osal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
				}
				if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
					glue << '${ind}st.rx_${msg}_st.on_receive(now)'
				}
				if secoc || e2e {
					glue << '\t\t\t}'
				}
				glue << '\t\t}'
			}
			for c in conns {
				tp := snake(c.name)
				glue << '\t\tif rx.id == u32(0x${c.rx_id.hex()}) {'
				glue << '\t\t\tmut p_${tp} := isotp.Pdu{}'
				glue << '\t\t\tfor i in 0 .. 8 {'
				glue << '\t\t\t\tp_${tp}.data[i] = rx.data[i]'
				glue << '\t\t\t}'
				glue << '\t\t\tst.tp_${tp}.on_frame(now, p_${tp})'
				glue << '\t\t}'
			}
			glue << '\t}'
			// rx deadline crossed -> publish invalid (valid=false) signals, once
			for msg, list in rx_by_msg {
				if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
					glue << '\tif st.rx_${msg}_st.expired(now) {'
					for sname in list {
						si := m.sig_of[sname] or { continue }
						fld := snake(sname)
						glue << '\t\tmut ${fld} := sig.${sname}{}'
						glue << '\t\tosal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
					}
					glue << '\t}'
				}
			}
			// ISO-TP + UDS: refresh live-signal DIDs, dispatch a reassembled
			// request, drain the segmented response.
			for c in conns {
				tp := snake(c.name)
				for idx, did in m.dids {
					if did.signal == '' {
						continue
					}
					si := m.sig_of[did.signal] or { continue }
					f := snake(did.signal)
					glue << '\tmut ${f}_did := sig.${did.signal}{}'
					glue << '\tif osal.${acquire_fn(si.transport)}(${f}_ch, &${f}_did, u8(sizeof(${f}_did))) {'
					glue << did_signal_encode(tp, idx, '${f}_did.${si.val_field}', si.val_type)
					glue << '\t}'
				}
				glue << '\t${tp}_n := st.tp_${tp}.take(&st.tp_${tp}_buf[0])'
				glue << '\tif ${tp}_n > 0 {'
				glue << '\t\t${tp}_rlen := st.uds_${tp}.handle(&st.tp_${tp}_buf[0], ${tp}_n, &st.uds_${tp}_resp[0])'
				glue << '\t\tif ${tp}_rlen > 0 {'
				glue << '\t\t\tst.tp_${tp}.send(&st.uds_${tp}_resp[0], ${tp}_rlen)'
				glue << '\t\t}'
				glue << '\t}'
				glue << '\tst.tp_${tp}.tick(now) // advance the ISO-TP timeout even when tx_ready gates poll out'
				glue << '\tmut pdu_${tp} := isotp.Pdu{}'
				// Gate on tx_ready so a UDS response burst never overruns the Tx FIFO or blocks — send at
				// most a FIFO\'s worth per pass, resume next pass (poll advances tx state).
				glue << '\tfor st.chan.tx_ready() && st.tp_${tp}.poll(now, mut pdu_${tp}) {'
				glue << '\t\tmut cf_${tp} := can.Frame{'
				glue << '\t\t\tid:  u32(0x${c.tx_id.hex()})'
				glue << '\t\t\tlen: 8'
				glue << '\t\t}'
				glue << '\t\tfor i in 0 .. 8 {'
				glue << '\t\t\tcf_${tp}.data[i] = pdu_${tp}.data[i]'
				glue << '\t\t}'
				glue << '\t\tst.chan.send(cf_${tp})'
				glue << '\t}'
			}
		}
		for msg, list in tx_by_msg {
			glue << '\tmut tx_${msg} := can.Frame{'
			glue << '\t\tid:  ${msg}_id'
			glue << '\t\tlen: ${msg}_dlc'
			glue << '\t}'
			glue << '\tmut tx_${msg}_any := false'
			for sname in list {
				si := m.sig_of[sname] or { continue }
				fld := snake(sname)
				phys := if si.val_type == 'bool' {
					'if ${fld}.${si.val_field} { f64(1) } else { f64(0) }'
				} else {
					'f64(${fld}.${si.val_field})'
				}
				glue << '\tmut ${fld} := sig.${sname}{}'
				glue << '\tif osal.${acquire_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld}))) {'
				glue << '\t\t${si.dbc_msg}_${snake(sname)}_set(mut tx_${msg}.data, ${phys})'
				glue << '\t\ttx_${msg}_any = true'
				glue << '\t}'
			}
			// Gate on tx_ready() BEFORE the change decision so a full Tx FIFO neither
			// advances the E2E/SecOC counter nor consumes the change/trigger — the PDU
			// just retries next tick (REQ-COM-006). mark_sent() commits the send only
			// once the channel accepts the frame.
			e2e_here := m.frames.e2e_on[msg] or { false }
			secoc_here := m.frames.secoc_on[msg] or { false }
			needs_pre := e2e_here || secoc_here
			glue << '\tif tx_${msg}_any && st.chan.tx_ready() && st.tx_${msg}_st.should_send(now, tx_${msg}.data, ${msg}_dlc) {'
			if needs_pre {
				glue << '\t\ttx_${msg}_pre := tx_${msg}.data // pre-E2E/SecOC payload, for change detection'
			}
			if e2e_here {
				// snapshot the alive counter so a rejected send can rewind it (protect()
				// advances the counter as a side effect); then stamp CRC + counter after the
				// change decision (so the counter doesn't make every frame look "changed").
				glue << '\t\te2e_save_${msg} := st.e2e_tx_${msg}'
				glue << '\t\tst.e2e_tx_${msg}.protect(&tx_${msg}.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or {
					0
				}).hex()}), ${m.frames.e2e_crc[msg] or { 0 }}, ${m.frames.e2e_ctr[msg] or { 0 }})'
			}
			if secoc_here {
				// snapshot freshness for the same rewind; then authenticate (stamp freshness
				// + truncated AES-CMAC) after the change decision.
				glue << '\t\tsecoc_save_${msg} := st.secoc_tx_${msg}'
				glue << '\t\tst.secoc_tx_${msg}.protect(&st.secoc_key_${msg}, &tx_${msg}.data[0], int(${msg}_dlc), u16(0x${(m.frames.secoc_id[msg] or {
					0
				}).hex()}), ${m.frames.secoc_fresh[msg] or { 0 }}, ${m.frames.secoc_mac[msg] or { 0 }}, ${m.frames.secoc_maclen[msg] or {
					0
				}})'
			}
			mark_arg := if needs_pre { 'tx_${msg}_pre' } else { 'tx_${msg}.data' }
			glue << '\t\tif st.chan.send(tx_${msg}) {'
			glue << '\t\t\tst.tx_${msg}_st.mark_sent(now, ${mark_arg}, ${msg}_dlc)'
			if e2e_here || secoc_here {
				// send rejected after tx_ready() (e.g. a multi-writer bus race, or a
				// nonblocking write losing queue space): rewind the protection counter so the
				// retry re-stamps the SAME value — otherwise the receiver sees a counter skip
				// and false-alarms a lost frame (E2E is ASIL B).
				glue << '\t\t} else {'
				if e2e_here {
					glue << '\t\t\tst.e2e_tx_${msg} = e2e_save_${msg}'
				}
				if secoc_here {
					glue << '\t\t\tst.secoc_tx_${msg} = secoc_save_${msg}'
				}
				glue << '\t\t}'
			} else {
				glue << '\t\t}'
			}
			glue << '\t}'
		}
		glue << '}'
		glue << ''
		mut psig := 'ch can.Channel'
		for d in dests {
			psig += ', route_${snake(d)} can.Channel'
		}
		glue << 'pub fn partition_${bb}(${psig}) {'
		glue << '\tosal.pin_to_core(${m.bus_core[bname] or { 0 }})'
		glue << '\tmut st := Bridge_${bb}_state{'
		glue << '\t\tchan: ch'
		glue << '\t}'
		for d in dests {
			glue << '\tst.route_${snake(d)} = route_${snake(d)}'
		}
		for msg, _ in tx_by_msg {
			mode := m.frames.tx_mode[msg] or { 'cyclic' }
			mut cyc := m.frames.tx_cycle_us[msg] or { 0 }
			if cyc == 0 {
				cyc = 100000 // default cyclic period when unspecified
			}
			glue << '\tst.tx_${msg}_st = com.TxState{'
			glue << '\t\tmode: com.TxMode.${mode}'
			glue << '\t\tcycle_us: ${cyc}'
			glue << '\t\tmin_delay_us: ${m.frames.tx_min_us[msg] or { 0 }}'
			glue << '\t}'
			if m.frames.secoc_on[msg] or { false } {
				glue << '\tst.secoc_key_${msg} = secoc.new_key(${byte16_lit(m.frames.secoc_key[msg] or {
					[]u8{}
				})})'
			}
		}
		for msg, _ in rx_by_msg {
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				glue << '\tst.rx_${msg}_st = com.RxState{'
				glue << '\t\ttimeout_us: ${m.frames.rx_timeout_us[msg]}'
				glue << '\t}'
			}
			if m.frames.secoc_on[msg] or { false } {
				glue << '\tst.secoc_key_${msg} = secoc.new_key(${byte16_lit(m.frames.secoc_key[msg] or {
					[]u8{}
				})})'
			}
		}
		for c in conns {
			tp := snake(c.name)
			glue << '\tst.tp_${tp} = isotp.Link{'
			glue << '\t\tbs:    ${c.bs}'
			glue << '\t\tstmin: ${c.stmin}'
			glue << '\t}'
			glue << '\tst.uds_${tp} = uds.Server{}'
			for idx, did in m.dids {
				glue << '\tst.uds_${tp}.dids[${idx}] = uds.Did{'
				glue << '\t\tid: u16(0x${did.id.hex()})'
				if did.writable {
					glue << '\t\twritable: true'
				}
				glue << '\t}'
				for bi, b in did.bytes {
					glue << '\tst.uds_${tp}.dids[${idx}].data[${bi}] = u8(0x${b.hex()})'
				}
				if did.bytes.len > 0 {
					glue << '\tst.uds_${tp}.dids[${idx}].len = ${did.bytes.len}'
				}
			}
			glue << '\tst.uds_${tp}.ndid = ${m.dids.len}'
		}
		glue << '\tmut sched := loom.Scheduler{}'
		glue << '\tsched.every(10_000, io_${bb}_10ms, &st)'
			glue << '\tfor {'
			glue << '\t\tloom_t0 := osal.now_us()'
			glue << '\t\tsched.run(loom_t0)'
			glue << '\t\tloom_t1 := osal.now_us()'
			glue << '\t\tsched.account(loom_t1 - loom_t0, loom_t1) // per-core load'
			for p in producers {
				glue << p.partition_loop_body('b:${bname}')
			}
			glue << '\t\tosal.sleep_us(1000)'
			glue << '\t}'
		glue << '}'
	}
	return glue, bus_names, bus_dests
}

// emit_run_target emits the on-target run(): the bare-metal / ThreadX single-core superloop
// (no osal, no spawn) plus — for the ThreadX target — comm_thread_entry and tx_application_define.
// Reads the Model; doc/all_regs/ioc_idx/msg_ioc_idx/telem_iface/comm_thread_on are main's emit state.
fn emit_run_target(m Model, doc toml.Doc, all_regs map[string][]string, telem_iface string, comm_thread_on bool, ioc_idx map[string]int, msg_ioc_idx map[int]int, producers []Producer) []string {
	mut glue := []string{}
		// --- target run(): one inline single-core superloop. No spawn, no osal. The
		//     timebase is the board's DWT clock (board_now_us); the loop paces to a
		//     (ThreadX comes here whether or not [trace] — its trace is the exec-hook stream
		//     added to this run() below, not the bare-metal polled trace path.)
		//     fixed tick so idle time between passes is real idle (the Loom measures
		//     load as run-time / wall-clock, so unpaced spinning would read ~50%). The
		//     CpuLoad frame is sent inline from load_permille() — no scratch, no tx
		//     thread. Takes the telemetry bus channel (main.v opens it after board init).
		// The target emits ONE app thread from the single FB-bearing partition. m.part.by_part is keyed
		// only by partitions that own fbs, so an extra FB-LESS partition would slip past a
		// m.part.by_part-only check yet still be created as a labelled thread by the manifest loop (which
		// walks every declared partition) — shifting the hook ids (e.g. the ThreadX System Timer
		// Thread id). Require exactly one DECLARED partition so declared == generated.
		np_declared := ecumodel.toml_arr(doc, 'partition').len
		if m.part.by_part.keys().len != 1 || np_declared != 1 {
			panic('loom2v: [target] supports exactly one partition (got ${np_declared} declared, ' +
				'${m.part.by_part.keys().len} with fbs) — a second or FB-less partition is never generated ' +
				'yet would still be labelled in the trace manifest; multi-partition/multi-core is not generated yet')
		}
		part := m.part.by_part.keys()[0]
		chp := snake(m.telem.bus)
		// ThreadX target config: the app thread's priority, the telem bus fd-mode + index, and
		// the sleep-per-pass in ThreadX ticks (1 tick = 1 ms; tx_initialize_low_level runs a 1 kHz
		// SysTick for the threadx target), all from ecu.toml rather than hardcoded.
		app_threads := m.part.threads_of[part] or { [''] }
		multi := app_threads.len > 1
		app_thread := app_threads[0]
		tx_prio := m.part.thread_prio[app_thread] or { 10 }
		// ThreadX priorities are 0..TX_MAX_PRIORITIES-1 (default 32); a value the schema type-checks
		// but the kernel rejects would make tx_thread_create fail and start no thread. Catch it here.
		// Multi-thread: every thread checked; the comm thread's priority is DERIVED as
		// min(app priorities) - 1, so it always preempts every app thread (e.g. 11/12/13 -> comm 10).
		mut min_prio := 32
		for thr in app_threads {
			pr := m.part.thread_prio[thr] or { 10 }
			if m.target.threadx && (pr < 0 || pr > 31) {
				panic('loom2v: [target] kind="threadx" thread "${thr}" priority ${pr} is out ' +
					'of the ThreadX range 0..31')
			}
			if pr < min_prio {
				min_prio = pr
			}
		}
		if multi && !m.target.threadx {
			panic('loom2v: multiple [[partition.thread]] need [target] kind="threadx" (one kernel ' +
				'thread per [[partition.thread]]); the bare-metal superloop is single-thread')
		}
		mut tx_bus_fd := false
		mut tx_bus_idx := '0'
		if m.target.threadx {
			if bc := doc.value('bus').as_map()[m.telem.bus] {
				tx_bus_fd = (bc.as_map()['fd'] or { toml.Any(false) }).bool()
			}
			// The register-level FDCAN backend is classic-only (blob_can_open rejects fd_mode), so
			// a CAN-FD telemetry bus would open -1 and the thread would exit. Reject it at gen time.
			if tx_bus_fd {
				panic('loom2v: [target] kind="threadx": bus "${m.telem.bus}" has fd = true, but the ' +
					'FDCAN backend used here is classic-only — set [bus.${m.telem.bus}].fd = false')
			}
			// The driver opens the bus by a SINGLE-digit index "0".."2" (blob_can_open reads
			// name[0]-'0'); derive it from the bus name (e.g. "can0" -> "0"). Require exactly one
			// digit in 0..2 — reject a name with no digit ("powertrain" -> bus 0 silently) OR an
			// ambiguous multi-digit one ("can10"/"can01", where the driver would read only '1'/'0').
			mut digits := ''
			for cc in m.telem.bus {
				if cc >= `0` && cc <= `9` {
					digits += cc.ascii_str()
				}
			}
			if digits.len != 1 || digits[0] < `0` || digits[0] > `2` {
				panic('loom2v: [target] kind="threadx": telemetry bus "${m.telem.bus}" must name a single ' +
					'FDCAN index 0..2 (e.g. "can0") — the driver opens buses by a one-digit index')
			}
			tx_bus_idx = digits
		}
		tx_sleep_ticks := if m.target.tick_us / 1000 > 1 { m.target.tick_us / 1000 } else { u64(1) }
		glue << ''
		glue << 'fn C.board_now_us() u64 // bare-metal monotonic µs (DWT cycle counter)'
		if m.target.threadx {
			// ThreadX target: the FB superloop runs inside a real ThreadX thread (paced by
			// tx_thread_sleep) that tx_application_define creates on tx_kernel_enter. TCB + stack
			// are static (globals). This partition has one thread; a multi-thread config would
			// emit one thread per partition.thread (+ a triple-buffer IOC for cross-thread signals).
			// The ThreadX API by FFI decl only (NOT #include "tx_api.h" — that pulls <string.h>,
			// whose strlen conflicts with V's own). The TCB is an opaque byte buffer (>= the
			// port's sizeof(TX_THREAD) = 200 B on cortex_m7); tx_thread_create just needs the
			// storage, and a void* is ABI-compatible with the TX_THREAD* the kernel expects.
			// The public tx_* names are macros in tx_api.h; without the header we bind the
			// real symbols the kernel exports (_tx_initialize_kernel_enter, _tx_thread_create,
			// _tx_thread_sleep).
			glue << 'fn C._tx_thread_sleep(u32) u32'
			glue << 'fn C._tx_initialize_kernel_enter()'
			glue << 'fn C._tx_thread_create(voidptr, &char, fn (u32), u32, voidptr, u32, u32, u32, u32, u32) u32'
			glue << trace_c_decls(m)
			glue << trace_fb_hooks(m, doc, app_threads, multi)
			if comm_thread_on {
				// Board glue (examples/<x>/comm_glue.c): the FDCAN Rx-FIFO0 ISR posts a semaphore
				// that comm_rx_wait blocks on, so the comm thread wakes on rx instead of polling.
				// comm_rx_irq_enable arms the Rx interrupt (called once, after the channel opens).
				glue << 'fn C.comm_rx_irq_enable()'
				glue << 'fn C.comm_rx_wait(u32) u32 // block up to N ticks; returns 0 if woken by rx'
				// Load scratch: the FB thread and the comm thread run on different ThreadX threads,
				// so the load cell is published/read through VOLATILE C accessors (comm_glue.c) — V
				// can't emit a volatile global, and a plain one could be cached at -Os so the comm
				// thread ships a stale CpuLoad. Single-writer/single-reader scalars, so no lock.
				if multi {
					glue << 'fn C.load_pub_slot(int, u32, u32, u32, u32, u32)'
					glue << 'fn C.load_sum_permille() u32'
					glue << 'fn C.load_sum_100ms() u32'
					glue << 'fn C.load_sum_1s() u32'
					glue << 'fn C.load_sum_10s() u32'
					glue << 'fn C.load_sum_overruns() u32'
				} else {
					glue << 'fn C.load_pub(u32, u32, u32, u32, u32)'
					glue << 'fn C.load_permille() u32'
					glue << 'fn C.load_100ms() u32'
					glue << 'fn C.load_1s() u32'
					glue << 'fn C.load_10s() u32'
					glue << 'fn C.load_overruns() u32'
				}
				if ioc_idx.len > 0 {
					// Target IOC pool (comm_glue.c, wait-free triple-buffer ioc.h): the comm thread
					// publishes a decoded rx signal into a cell (ioc_pub), an FB reads it (ioc_get);
					// ioc_pool_init runs once before the kernel starts.
					glue << 'fn C.ioc_pool_init()'
					glue << 'fn C.ioc_pub(int, u32, u32)'
					glue << 'fn C.ioc_get(int, &u32, &u32)'
				}
			}
			glue << ''
			// TCB as [32]u64 (256 B >= sizeof(TX_THREAD) = 200 B) so it is 8-byte aligned — the
			// kernel reads/writes word fields through this pointer as a TX_THREAD*, so a byte-
			// aligned [256]u8 could fault. The stack stays a byte buffer (ThreadX aligns the SP
			// internally in tx_thread_stack_build).
			glue << '__global ('
			for thr in app_threads {
				own := if multi { thr } else { part }
				glue << '\tg_${own}_tcb   [32]u64  // >= sizeof(TX_THREAD) (200 B), 8-byte aligned'
				glue << '\tg_${own}_stack [4096]u8'
			}
			glue << trace_scratch_fields(m, part)
			glue << trace_module_globals(m)
			if comm_thread_on {
				glue << '\tg_comm_tcb   [32]u64  // the bus-owning comm thread'
				glue << '\tg_comm_stack [4096]u8'
				// (The load cell is the volatile C scratch in comm_glue.c, via load_pub/load_*.)
				// Rx accounting: the comm thread counts received frames + keeps the last value, so a
				// host cansend is observable. The rx CONSUMER of the lean cut (comm-thread-local).
				glue << '\tg_rx_count u32'
				glue << '\tg_rx_last  u32'
			}
			glue << ')'
		}
		glue << ''
		if multi {
			// One kernel thread per [[partition.thread]]: each gets its own state, scheduler, and
			// (fb-traced) hook; each publishes its load to its own scratch slot (the comm thread
			// sums them for CpuLoad). Priorities come from the config; ThreadX preempts by them —
			// exactly what the trace's swimlane is for.
			for ti, thr in app_threads {
				glue << 'fn run_${thr}() {'
				glue << '\tmut st := Thread_${thr}_state{}'
				glue << '\tmut sched := loom.Scheduler{}'
				for r in all_regs['${part}/${thr}'] or { []string{} } {
					glue << r
				}
				glue << '\ttick_us := u64(${m.target.tick_us})'
				if m.trace.on && m.trace.level == 'all' {
					glue << '\tsched.set_trace_hook(trace_fb_hook_${thr}, unsafe { nil })'
				}
				glue << '\tfor {'
				glue << '\t\tt0 := C.board_now_us()'
				if m.trace.on && m.trace.level == 'all' {
					glue << '\t\tsched.run_profiled(trace_clock)'
					glue << '\t\tt1 := C.board_now_us()'
				} else {
					glue << '\t\tsched.run(t0)'
					glue << '\t\tt1 := C.board_now_us()'
					glue << "\t\tsched.account(t1 - t0, t1) // handler time -> this thread's load"
				}
				glue << '\t\tif t1 - t0 > tick_us { // pass exceeded its tick budget -> overrun'
				glue << '\t\t\tsched.mark_overrun()'
				glue << '\t\t}'
				glue << '\t\tC.load_pub_slot(${ti}, u32(sched.load_permille()), u32(sched.load_permille_100ms()),'
				glue << '\t\t\tu32(sched.load_permille_1s()), u32(sched.load_permille_10s()), sched.overruns())'
				glue << '\t\tC._tx_thread_sleep(u32(${tx_sleep_ticks}))'
				glue << '\t}'
				glue << '}'
				glue << ''
			}
		}
		if !multi && comm_thread_on {
			// The FB thread stays OFF CAN: the comm thread owns the bus. run() just dispatches the
			// FBs and publishes load to the scratch cell for the comm thread to send.
			glue << 'pub fn run() {'
		} else if !multi {
			glue << 'pub fn run(${chp} can.Channel) {'
			glue << '\tmut ch := ${chp}'
		}
		if !multi {
		glue << '\tmut st := Partition_${part}_state{}'
		glue << '\tmut sched := loom.Scheduler{}'
		for r in all_regs[part] or { []string{} } {
			glue << r
		}
		if m.telem.on && telem_iface != '' && !comm_thread_on {
			glue << '\tmut load := [8]u16{}'
			glue << '\ttelem_period_us := u64(${m.telem.period_us})'
			glue << '\tmut last_telem := u64(0)'
			if m.telem.detail_id != 0 {
				glue << '\tmut last_overruns := u32(0) // for the per-period overrun count'
			}
		}
		glue << '\ttick_us := u64(${m.target.tick_us})'
		if !m.target.threadx {
			glue << '\tmut next_tick := C.board_now_us() + tick_us'
		}
		glue << trace_fb_install(m)
		glue << '\tfor {'
		glue << '\t\tt0 := C.board_now_us()'
		if m.trace.on && m.trace.level == 'all' {
			// profiled dispatch: run_profiled accounts internally and fires the FB trace hook
			glue << '\t\tsched.run_profiled(trace_clock)'
			glue << '\t\tt1 := C.board_now_us()'
		} else {
			glue << '\t\tsched.run(t0)'
			glue << '\t\tt1 := C.board_now_us()'
			glue << "\t\tsched.account(t1 - t0, t1) // handler time -> this core's load"
		}
		glue << '\t\tif t1 - t0 > tick_us { // pass exceeded its tick budget -> overrun'
		glue << '\t\t\tsched.mark_overrun()'
		glue << '\t\t}'
		if comm_thread_on {
			// Publish this core's load to the volatile scratch (single writer) for the comm thread's
			// CpuLoad producer. Single M7 -> core 0 only; the comm thread reads it each telemetry
			// period. load_pub takes all fields (detail ones are 0 if unused — cheap, keeps it one call).
			glue << '\t\tC.load_pub(u32(sched.load_permille()), u32(sched.load_permille_100ms()),'
			glue << '\t\t\tu32(sched.load_permille_1s()), u32(sched.load_permille_10s()), sched.overruns())'
		}
		for p in producers {
			glue << p.bus_tick(BusCtx{
				telem_active: m.telem.on && telem_iface != '' && !comm_thread_on
				now:          't1'
				period:       'telem_period_us'
				load:         ['\t\t\tload[0] = sched.load_permille() // single M7 -> core 0 only']
				det_ovr:      'sched.overruns()'
				det_lines:    ['\t\t\tdetail := telem.encode_loaddetail(sched.load_permille_100ms(),', '\t\t\t\tsched.load_permille_1s(), sched.load_permille_10s(), ovr - last_overruns)']
				frame:        'f'
				detframe:     'd'
				idx:          'i'
			})
		}
		if m.target.threadx {
			// Yield to the RTOS between passes: sleep the configured tick (in 1 ms ThreadX
			// ticks), so lower-priority threads run and the Loom's load = run-time / wall-clock
			// stays honest (no busy-wait). ThreadX runs a 1 kHz SysTick for the threadx target.
			glue << '\t\tC._tx_thread_sleep(u32(${tx_sleep_ticks}))'
		} else {
			glue << '\t\tfor C.board_now_us() < next_tick {} // idle to the tick (real idle)'
			glue << '\t\tnext_tick += tick_us'
			glue << '\t\tnow := C.board_now_us()'
			glue << '\t\tif now > next_tick { // a pass overran the tick — resync'
			glue << '\t\t\tnext_tick = now + tick_us'
			glue << '\t\t}'
		}
		glue << '\t}'
		glue << '}'
		}
		if m.target.threadx {
			// The ThreadX app thread + the kernel's application-define entry. main.v does the board
			// clock/CAN init then C.tx_kernel_enter(), which calls tx_application_define below.
			glue << ''
			if comm_thread_on {
				// The comm thread must be STRICTLY higher priority (lower number) than the FB thread
				// so it preempts a long app pass to drain rx after the ISR posts (zero time slice
				// means no round-robin). With comm fixed at 1, the app thread must be >= 2.
				if min_prio <= 1 {
					panic('loom2v: [target] kind="threadx" comm thread needs a priority strictly higher ' +
						'than every FB thread, but the highest FB priority is ${min_prio}; use ' +
						'priorities >= 2 so the comm owner preempts them to drain rx promptly')
				}
				// Single-thread keeps the historical comm priority 1; multi-thread derives it as
				// min(app priorities) - 1, so realistic numbering (apps 11/12/13 -> comm 10) works
				// without a separate config knob and comm ALWAYS outranks the apps.
				comm_prio := if multi { min_prio - 1 } else { 1 }
				// The Rx-ISR board glue (comm_glue.c) enables FDCAN1's FIFO0 interrupt + NVIC line
				// specifically. A telemetry/rx bus that opens FDCAN2/3 (index 1/2) would drain only on
				// the 10-tick timeout (no ISR wake -> FIFO loss under bursts). The per-instance IRQ glue
				// is target work (see docs/architecture.md "Interrupts and the generic <-> target
				// boundary") — until then the lean cut owns FDCAN1 only.
				if tx_bus_idx != '0' {
					panic('loom2v: [target] kind="threadx" comm thread: the Rx-ISR glue serves FDCAN1 ' +
						'(bus index 0) only, but bus "${m.telem.bus}" opens index ${tx_bus_idx}; use a ' +
						'can0/index-0 bus, or add per-instance IRQ glue (phase 6b-2b)')
				}
				// One rx branch per DBC MESSAGE (id), not per signal — several signals can share a
				// message, and the lean cut counts received frames, so a frame must increment once.
				mut rx_sigs := []SigInfo{}
				mut rx_ids_seen := map[int]bool{}
				for sn in m.sig_names {
					s := m.sig_of[sn] or { continue }
					if s.rx && !rx_ids_seen[s.dbc_id] {
						rx_ids_seen[s.dbc_id] = true
						rx_sigs << s
					}
				}
				// external TX signals (FB writes -> IOC -> comm sends), a producer each.
				mut tx_sigs := []SigInfo{}
				for sn in m.sig_names {
					s := m.sig_of[sn] or { continue }
					if s.external && !s.rx {
						tx_sigs << s
					}
				}
				// The FB thread(s) run OFF CAN (publishing load to their scratch slot); the comm
				// thread owns the bus. ThreadX: lower priority number = higher priority.
				if multi {
					for thr in app_threads {
						glue << 'fn ${thr}_thread_entry(input u32) {'
						glue << '\trun_${thr}() // FB dispatch only — the comm thread owns the bus'
						glue << '}'
						glue << ''
					}
				} else {
					glue << 'fn ${part}_thread_entry(input u32) {'
					glue << '\trun() // FB dispatch only — the comm thread owns the bus'
					glue << '}'
					glue << ''
				}
				// The comm thread: the sole bus owner. A generic loop — drain rx (consumer), then
				// serve each producer (CpuLoad telemetry, the trace ring) gated on tx_ready. Nothing
				// here is trace-specific: NM and COM-tx will slot in later as more producers/consumers.
				// the comm thread reads the FB thread(s)' load: one scratch (single) or the slot sums.
				comm_load_line := if multi {
					'\t\t\tload[0] = u16(C.load_sum_permille()) // sum of the FB threads (one core)'
				} else {
					'\t\t\tload[0] = u16(C.load_permille())'
				}
				comm_det_ovr := if multi { 'C.load_sum_overruns()' } else { 'C.load_overruns()' }
				comm_det_line := if multi {
					'\t\t\tdetail := telem.encode_loaddetail(u16(C.load_sum_100ms()), u16(C.load_sum_1s()), u16(C.load_sum_10s()), ovr - last_overruns)'
				} else {
					'\t\t\tdetail := telem.encode_loaddetail(u16(C.load_100ms()), u16(C.load_1s()), u16(C.load_10s()), ovr - last_overruns)'
				}
			glue << 'fn comm_thread_entry(input u32) {'
				glue << '\tmut ch := can.Channel{}'
				glue << "\tif !ch.open('${tx_bus_idx}', ${tx_bus_fd}) { // ${m.telem.bus}; board clocks/pins set by main.v"
				glue << '\t\tfor { C._tx_thread_sleep(1000) } // dead channel — park, never own a bus we can\'t drive'
				glue << '\t}'
				glue << '\tC.comm_rx_irq_enable() // arm the FDCAN Rx-FIFO0 interrupt now the bus is open'
				if m.telem.on && telem_iface != '' {
					glue << '\tmut last_telem := u64(0)'
					glue << '\ttelem_period_us := u64(${m.telem.period_us})'
					if m.telem.detail_id != 0 {
						glue << '\tmut last_overruns := u32(0)'
					}
				}
				glue << trace_module_init(m)
				for si in tx_sigs {
					glue << '\tmut last_tx_${snake(si.name)} := u64(0)'
				}
				glue << '\tmut rx := can.Frame{}'
				glue << '\tfor {'
				if m.trace.on {
					// While a dump stream is in flight, wake every tick: the Tx FIFO holds ~3
					// frames, so a 10-tick pace stretches a 75-frame block to ~300 ms (blowing
					// host budgets); at 1 tick it drains in ~25 ms.
					glue << '\t\twait_ticks := if g_tm.is_dumping() { u32(1) } else { u32(10) }'
					glue << '\t\tC.comm_rx_wait(wait_ticks) // the FDCAN Rx ISR wakes us early on a new frame'
				} else {
					glue << '\t\tC.comm_rx_wait(10) // block up to 10 ticks; the FDCAN Rx ISR wakes us on a new frame'
				}
				glue << '\t\t// CONSUMER: drain the Rx FIFO (non-blocking); account each external rx frame'
				glue << '\t\tfor ch.recv(mut rx) {'
				for si in rx_sigs {
					// Gate on the DBC DLC too: recv reuses the frame and copies only the bytes that
					// arrived, so a short same-id frame would leave stale high bytes in the decode.
					glue << '\t\t\tif rx.id == u32(0x${si.dbc_id.hex()}) && rx.len == ${si.dbc_dlc} { // ${si.dbc_msg}'
					glue << '\t\t\t\tg_rx_count++'
					glue << '\t\t\t\tg_rx_last = u32(rx.data[0]) | (u32(rx.data[1]) << 8) | (u32(rx.data[2]) << 16) | (u32(rx.data[3]) << 24)'
					if idx := msg_ioc_idx[si.dbc_id] {
						// This message carries an FB-read signal (keyed by DBC id, so it fires even when
						// the de-duped representative is a different, un-read signal): publish the decoded
						// value (byte-0 scalar) into its IOC cell so the app thread picks it up wait-free.
						glue << '\t\t\t\tC.ioc_pub(${idx}, g_rx_last, u32(0))'
					}
					glue << '\t\t\t}'
				}
				glue << trace_rx_arms(m, part)
				glue << '\t\t}'
				glue << '\t\tt1 := C.board_now_us()'
				for p in producers {
					glue << p.bus_tick(BusCtx{
						telem_active: m.telem.on && telem_iface != ''
						lead:         ["\t\t// PRODUCER: CpuLoad telemetry — reads the FB thread's load scratch"]
						now:          't1'
						period:       'telem_period_us'
						gate:         ' && ch.tx_ready()'
						load:         ['\t\t\tmut load := [8]u16{}', comm_load_line]
						det_ovr:      comm_det_ovr
						det_lines:    [comm_det_line]
						frame:        'f'
						detframe:     'd'
						idx:          'i'
					})
				}
				for si in tx_sigs {
					mut cyc := m.frames.tx_cycle_us[si.dbc_msg] or { 0 }
					if cyc <= 0 {
						cyc = 100000 // default cyclic 100 ms if no [[frame]].tx.cycle_ms
					}
					idx := ioc_idx[si.name] or { 0 }
					glue << '\t\t// PRODUCER: external tx signal "${si.name}" — read the FB-published IOC'
					glue << '\t\t// cell, encode the value (LE at byte 0), and send it cyclically (tx_ready-gated).'
					glue << '\t\tif t1 - last_tx_${snake(si.name)} >= u64(${cyc}) && ch.tx_ready() {'
					glue << '\t\t\tlast_tx_${snake(si.name)} = t1'
					glue << '\t\t\tmut tv_a := u32(0)'
					glue << '\t\t\tmut tv_b := u32(0)'
					glue << '\t\t\tC.ioc_get(${idx}, &tv_a, &tv_b)'
					glue << '\t\t\tmut tf := can.Frame{'
					glue << '\t\t\t\tid:  u32(0x${si.dbc_id.hex()})'
					glue << '\t\t\t\tlen: ${si.dbc_dlc}'
					glue << '\t\t\t}'
					glue << '\t\t\ttf.data[0] = u8(tv_a & 0xff)'
					glue << '\t\t\ttf.data[1] = u8((tv_a >> 8) & 0xff)'
					glue << '\t\t\ttf.data[2] = u8((tv_a >> 16) & 0xff)'
					glue << '\t\t\ttf.data[3] = u8((tv_a >> 24) & 0xff)'
					glue << '\t\t\tch.send(tf)'
					glue << '\t\t}'
				}
				glue << trace_produce_drain(m)
				glue << '\t}'
				glue << '}'
				glue << ''
				glue << "@[export: 'tx_application_define']"
				glue << 'fn tx_application_define(first_unused voidptr) {'
				if multi {
					for thr in app_threads {
						pr := m.part.thread_prio[thr] or { 10 }
						glue << '\tC._tx_thread_create(&g_${thr}_tcb[0], c\'${thr}\', ${thr}_thread_entry, u32(0),'
						glue << '\t\t&g_${thr}_stack[0], u32(g_${thr}_stack.len), u32(${pr}), u32(${pr}), u32(0), u32(1))'
					}
				} else {
					glue << '\tC._tx_thread_create(&g_${part}_tcb[0], c\'${part}\', ${part}_thread_entry, u32(0),'
					glue << '\t\t&g_${part}_stack[0], u32(g_${part}_stack.len), u32(${tx_prio}), u32(${tx_prio}), u32(0), u32(1))'
				}
				glue << '\tC._tx_thread_create(&g_comm_tcb[0], c\'comm\', comm_thread_entry, u32(0),'
				glue << '\t\t&g_comm_stack[0], u32(g_comm_stack.len), u32(${comm_prio}), u32(${comm_prio}), u32(0), u32(1))'
				if m.trace.on {
					// Deterministic trace thread ids (manifest order): comm = 1, then the app
					// threads by priority; the ONLY first-sight id left is the ThreadX timer
					// thread — always last, exactly as the manifest's tx_system_timer row says.
					glue << '\tC.trace_bind_thread(&g_comm_tcb[0])'
					if multi {
						for thr in app_threads {
							glue << '\tC.trace_bind_thread(&g_${thr}_tcb[0])'
						}
					} else {
						glue << '\tC.trace_bind_thread(&g_${part}_tcb[0])'
					}
				}
				glue << '}'
			} else {
				glue << 'fn ${part}_thread_entry(input u32) {'
				glue << '\tmut ch := can.Channel{}'
				glue << "\tif !ch.open('${tx_bus_idx}', ${tx_bus_fd}) { // ${m.telem.bus}; board clocks/pins set by main.v"
				glue << '\t\treturn // CAN open failed (bad bus index / FD unsupported) — don\'t run with a dead channel'
				glue << '\t}'
				glue << '\trun(ch)'
				glue << '}'
				glue << ''
				glue << "@[export: 'tx_application_define']"
				glue << 'fn tx_application_define(first_unused voidptr) {'
				glue << '\tC._tx_thread_create(&g_${part}_tcb[0], c\'${part}\', ${part}_thread_entry, u32(0),'
				glue << '\t\t&g_${part}_stack[0], u32(g_${part}_stack.len), u32(${tx_prio}), u32(${tx_prio}), u32(0), u32(1))'
				glue << '}'
			}
			glue << ''
			glue << '// boot: hand control to the ThreadX kernel (never returns; calls'
			glue << '// tx_application_define above). main.v does the board bring-up then calls this —'
			glue << '// referencing it also forces this module (incl. tx_application_define) to link.'
			glue << 'pub fn boot() {'
			if ioc_idx.len > 0 {
				glue << '\tC.ioc_pool_init() // init the cross-thread signal IOC cells before any thread runs'
			}
			glue << '\tC._tx_initialize_kernel_enter()'
			glue << '}'
		}
	return glue
}

// emit_run_host emits the plain multi-core host run(): launch every bus bridge + app partition,
// then wait. One Channel param per bus (sorted for a stable signature). Reads the Model; telem_iface
// / bus_names / bus_dests / extra_dest_buses are main's emit-time state.
fn emit_run_host(m Model, telem_iface string, bus_names []string, bus_dests map[string][]string, extra_dest_buses []string) []string {
	mut glue := []string{}
		// --- host run(): launch every bus bridge + app partition, then wait. One
		//     Channel param per bus (sorted for a stable signature main.v can rely on). ---
		glue << ''
		mut waits := []string{}
		if bus_names.len == 0 {
			glue << 'pub fn run() {'
		} else {
			mut params := []string{}
			for b in bus_names {
				params << '${snake(b)} can.Channel'
			}
			for b in extra_dest_buses {
				params << '${snake(b)} can.Channel' // route-dest-only bus: channel arg, no bridge
			}
			glue << 'pub fn run(${params.join(', ')}) {'
			for b in bus_names {
				bb := snake(b)
				mut spawn_args := bb
				for d in bus_dests[b] or { []string{} } {
					spawn_args += ', ${snake(d)}'
				}
				glue << '\tt_${bb} := spawn partition_${bb}(${spawn_args})'
				waits << 't_${bb}'
			}
		}
		for part, _ in m.part.by_part {
			glue << '\tt_${part} := spawn partition_${part}(${m.part.core_of[part] or { 0 }}, unsafe { nil })'
			waits << 't_${part}'
		}
		if m.telem.on && telem_iface != '' {
			glue << '\tt_telem := spawn partition_telem()'
			waits << 't_telem'
		}
		for w in waits {
			glue << '\t${w}.wait()'
		}
		glue << '}'
	return glue
}

// emit_handlers emits, per partition: its state struct, each handler's port structs (module ports)
// and dispatch glue (module gen), the host partition_<p>() runner, and builds all_regs (the
// sched.every() lines the run() emitters reuse). Returns (ports, glue, all_regs); reads the Model,
// with the derived scratch/id layout (telem_slot, ioc_idx, trace bases, fb_id_base, thread_id_of)
// and the trace-mode flags from main's emit-time state.
fn emit_handlers(m Model, producers []Producer, ioc_idx map[string]int, trace_host bool) ([]string, []string, map[string][]string) {
	mut ports := []string{}
	mut glue := []string{}
	mut all_regs := map[string][]string{}
	for part, clist in m.part.by_part {
		threads := m.part.threads_of[part] or { [''] }
		multi := threads.len > 1
		// Which thread serves each fb, and which thread WRITES each local signal (its cell lives
		// in that thread's state). A local signal read from another thread would race two
		// schedulers — reject it: cross-thread fan-out is the IOC's job, not a shared struct's.
		mut fb_thr := map[string]string{}
		mut sig_writer_thr := map[string]string{}
		for c in clist {
			cm := c.as_map()
			cname := (cm['name'] or { toml.Any('') }).string()
			thr := m.part.fb_thread[cname] or { threads[0] }
			fb_thr[cname] = thr
			for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				for w in (h.as_map()['writes'] or { toml.Any([]toml.Any{}) }).array() {
					wsi := m.sig_of[w.string()] or { continue }
					if wsi.local {
						sig_writer_thr[w.string()] = thr
					}
				}
			}
		}
		if multi {
			for c in clist {
				cm := c.as_map()
				cname := (cm['name'] or { toml.Any('') }).string()
				for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
					for r in (h.as_map()['reads'] or { toml.Any([]toml.Any{}) }).array() {
						rsi := m.sig_of[r.string()] or { continue }
						if rsi.local && (sig_writer_thr[r.string()] or { '' }) != fb_thr[cname] {
							panic('loom2v: local signal "${r.string()}" is written on thread ' +
								'"${sig_writer_thr[r.string()]}" but read by fb "${cname}" on thread ' +
								'"${fb_thr[cname]}" — cross-thread signals need the IOC fan-out (not ' +
								'generated yet); keep the writer and readers on one thread')
						}
					}
				}
			}
		}
		// one state struct per THREAD (single-thread keeps the historical partition-wide name, so
		// every existing config generates byte-identically).
		for thr in threads {
			sname_t := if multi { 'Thread_${thr}_state' } else { 'Partition_${part}_state' }
			glue << ''
			glue << 'struct ${sname_t} {'
			glue << 'mut:'
			for c in clist {
				cname := (c.as_map()['name'] or { toml.Any('') }).string()
				if fb_thr[cname] != thr && multi {
					continue
				}
				glue << '\t${snake(cname)} app.${cname}'
			}
			for sname in m.sig_names {
				si := m.sig_of[sname] or { continue }
				if si.local && si.from == part {
					if multi && (sig_writer_thr[sname] or { threads[0] }) != thr {
						continue
					}
					glue << '\tcell_${snake(sname)} sig.${sname} // local FB->FB signal'
				}
			}
			glue << '}'
		}

		mut regs := []string{}
		for c in clist {
			cm := c.as_map()
			cname := (cm['name'] or { toml.Any('') }).string()
			field := snake(cname)
			for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hm := h.as_map()
				hname := (hm['name'] or { toml.Any('') }).string()
				period_us := int((hm['period_ms'] or { toml.Any(0) }).int()) * 1000
				reads := (hm['reads'] or { toml.Any([]toml.Any{}) }).array()
				writes := (hm['writes'] or { toml.Any([]toml.Any{}) }).array()

				// --- port structs (module ports) ---
				ports << ''
				ports << 'pub struct ${cname}In {'
				ports << 'pub mut:'
				for r in reads {
					ports << provenance(r.string(), m.sig_of)
					ports << '\t${snake(r.string())} sig.${r.string()}'
				}
				ports << '}'
				ports << 'pub struct ${cname}Out {'
				ports << 'pub mut:'
				for w in writes {
					ports << provenance(w.string(), m.sig_of)
					ports << '\t${snake(w.string())} sig.${w.string()}'
				}
				ports << '}'

				// --- glue handler (module gen) ---
				gname := 'handler_${part}_${field}_${hname}'
				ctx_struct := if multi { 'Thread_${fb_thr[cname]}_state' } else { 'Partition_${part}_state' }
				glue << ''
				glue << 'fn ${gname}(ctx voidptr) {'
				glue << '\tmut st := unsafe { &${ctx_struct}(ctx) }'
				glue << '\tmut inp := ports.${cname}In{}'
				for r in reads {
					rn := r.string()
					si := m.sig_of[rn] or { SigInfo{} }
					if si.local {
						glue << '\tinp.${snake(rn)} = st.cell_${snake(rn)} // local'
					} else if idx := ioc_idx[rn] {
						// bus -> comm(decode) -> target IOC cell ${idx} -> this FB input (6b-2b). One
						// ioc_get per read (it advances the reader slot); the value field is `a`.
						glue << '\tmut ${snake(rn)}_a := u32(0)'
						glue << '\tmut ${snake(rn)}_b := u32(0)'
						glue << '\tC.ioc_get(${idx}, &${snake(rn)}_a, &${snake(rn)}_b)'
						glue << '\tinp.${snake(rn)}.${snake(si.val_field)} = ${si.val_type}(${snake(rn)}_a)'
					} else {
						glue << '\tosal.${acquire_fn(si.transport)}(${snake(rn)}_ch, &inp.${snake(rn)}, u8(sizeof(inp.${snake(rn)})))'
					}
				}
				glue << '\tmut outp := ports.${cname}Out{}'
				glue << '\tst.${field}.${hname}(inp, mut outp)'
				for w in writes {
					wn := w.string()
					si := m.sig_of[wn] or { SigInfo{} }
					if si.local {
						glue << '\tst.cell_${snake(wn)} = outp.${snake(wn)} // local'
					} else if idx := ioc_idx[wn] {
						// external TX (app -> bus): publish the value into its IOC cell; the comm thread
						// reads it each tx period, encodes, and sends. Value field -> sig_t.a (b unused).
						glue << '\tC.ioc_pub(${idx}, u32(outp.${snake(wn)}.${snake(si.val_field)}), u32(0))'
					} else {
						glue << '\tosal.${publish_fn(si.transport)}(${snake(wn)}_ch, &outp.${snake(wn)}, u8(sizeof(outp.${snake(wn)})))'
					}
				}
				glue << '}'
				if multi {
					all_regs['${part}/${fb_thr[cname]}'] << '\tsched.every(${period_us}, ${gname}, &st)'
				} else {
					regs << '\tsched.every(${period_us}, ${gname}, &st)'
				}
			}
		}
		all_regs[part] = regs.clone()

		// One spawned superloop per partition (host mode + the multi-core traced path). Target mode
		// emits a single inline superloop in run() instead; inline-trace folds the (single) partition
		// into run(ch). The skeleton is one shape; producers inject preamble / loop-top / dispatch /
		// loop-body (trace: capture ctx + command poll + profiled dispatch; telem: the load publish),
		// so this emitter names no capability.
		if !m.target.on && !trace_host {
			glue << ''
			glue << 'pub fn partition_${part}(core int, arg voidptr) {'
			glue << '\tosal.pin_to_core(${m.part.core_of[part] or { 0 }})'
			glue << '\tmut st := Partition_${part}_state{}'
			glue << '\tmut sched := loom.Scheduler{}'
			for r in regs {
				glue << r
			}
			for p in producers {
				glue << p.partition_preamble('p:${part}')
			}
			glue << '\tfor {'
			for p in producers {
				glue << p.partition_loop_top('p:${part}')
			}
			mut disp := [
				'\t\tloom_t0 := osal.now_us()',
				'\t\tsched.run(loom_t0)',
				'\t\tloom_t1 := osal.now_us()',
				'\t\tsched.account(loom_t1 - loom_t0, loom_t1) // per-core load',
			]
			for p in producers {
				d := p.partition_dispatch('p:${part}')
				if d.len > 0 {
					disp = d.clone()
				}
			}
			for l in disp {
				glue << l
			}
			for p in producers {
				glue << p.partition_loop_body('p:${part}')
			}
			glue << '\t\tosal.sleep_us(1000)'
			glue << '\t}'
			glue << '}'
		}
	}
	return ports, glue, all_regs
}

// emit_module_headers builds the `module ports` and `module gen` preambles: the code-gen banner,
// module decl, and the conditional imports each generated module needs. Returns (ports, glue) seeded
// with those header lines; reads the Model, with the trace-mode flags + comm_thread_on from main.
fn emit_module_headers(m Model, ecu string, comm_thread_on bool, trace_host bool) ([]string, []string) {
	has_e2e := m.frames.e2e_on.len > 0
	has_secoc := m.frames.secoc_on.len > 0
	mut ports := []string{}
	ports << '// Code generated by tools/loom2v from ${os.file_name(ecu)} — DO NOT EDIT.'
	ports << 'module ports'
	ports << ''
	// Port structs carry sig.* fields only when there are signals; a pure-compute app (e.g. a
	// trace demo) has none, so skip the import rather than emit an unused-import warning.
	if m.sig_names.len > 0 {
		ports << 'import sig'
	}

	// glue references sig.* only for local-cell types; import it only if needed.
	mut has_local := false
	for part, _ in m.part.by_part {
		for sname in m.sig_names {
			si := m.sig_of[sname] or { continue }
			if si.local && si.from == part {
				has_local = true
			}
		}
	}

	mut glue := []string{}
	glue << '// Code generated by tools/loom2v from ${os.file_name(ecu)} — DO NOT EDIT.'
	glue << 'module gen'
	glue << ''
	if has_local || m.has_external {
		glue << 'import sig' // local-cell types and/or bus-bridge signal structs
	}
	glue << 'import ports'
	glue << 'import app'
	glue << 'import loom'
	if !m.target.on {
		glue << 'import osal' // host: IOC + now_us/sleep_us. Target has none of these.
	}
	// telem.* is used for CpuLoad (telemetry) — import it only when it's actually emitted.
	if m.telem.on {
		glue << 'import comm.telem' // CpuLoad packing
	}
	if trace_host || (m.trace.on && m.target.threadx) {
		glue << 'import comm.trace' // the TraceModule + ring + hooks (docs/com-modules.md)
	}
	if m.has_external || m.isotp_conns.len > 0 || m.telem.on {
		glue << 'import driver.can' // the generated bus bridge
	}
	if m.has_external && !comm_thread_on {
		glue << 'import comm.com' // per-PDU TX modes + RX deadline monitoring (host bridge only)
	}
	if has_e2e {
		glue << 'import comm.e2e' // end-to-end protection (CRC + alive counter)
	}
	if has_secoc {
		glue << 'import comm.secoc' // SecOC authentication (AES-CMAC + freshness)
	}
	if m.isotp_conns.len > 0 {
		glue << 'import comm.isotp' // ISO-TP diagnostic transport
		glue << 'import comm.uds' // UDS diagnostic services
	}
	return ports, glue
}

fn main() {
	args := os.args
	if args.len < 6 {
		eprintln('usage: loom2v <ecu.toml> <bus.dbc> <signals_out> <ports_out> <glue_out> [manifest_out]')
		exit(2)
	}
	ecu := args[1]
	dbc := args[2]
	doc := toml.parse_file(ecu) or { panic('parse ${ecu}: ${err}') }

	// Validate the partition/thread/fb structure FIRST — the rules live in ecumodel, shared with
	// ecucheck so the gate and generator can't drift — BEFORE any DBC/signal parsing below, which
	// would otherwise panic on a DBC issue for a config that is structurally invalid anyway.
	// Everything after this assumes a valid structure (no re-validation).
	verrs := ecumodel.validate(doc)
	if verrs.len > 0 {
		panic('loom2v: invalid ecu.toml:\n  ' + verrs.join('\n  '))
	}

	// Single parse pass: ecu.toml + bus.dbc -> the Model. The emit code below reads from `m`
	// (rebound to the existing locals so it stays unchanged). (Step (a): parse -> model.)
	m := build_model(doc, dbc)

	// [trace]: the ThreadX exec-hook stream is the generated path (gen_trace.v); validate what it
	// can honour. The host/bare-metal command-driven protocol moved to the platform (comm/trace
	// TraceModule, docs/com-modules.md) and lands via frame->module routing — warn, don't silently
	// drop, until that wiring exists.
	// trace_host: the single-core host module runner (one partition, no COM bridge) — ONE loop
	// owns the schedule and the bus, serving comm/trace's TraceModule via the endpoint bindings.
	trace_host := m.trace.on && !m.target.on && m.part.by_part.keys().len == 1
		&& !(m.has_external || m.isotp_conns.len > 0 || m.routes.len > 0)
	if m.trace.on && m.target.threadx {
		validate_trace_threadx(m)
	} else if m.trace.on && !trace_host {
		eprintln('loom2v: WARNING: [trace] on this shape (bare-metal target, multi-partition, or ' +
			'a COM bridge on the trace bus) is not generated yet — the module runner covers the ' +
			'single-core host shape (docs/com-modules.md). Building WITHOUT trace.')
	}

	// [[signal]] -> the model, then emit the `sig` module.
	signals := emit_signals(m.sig_of, m.sig_names, ecu)

	// Per-PDU COM behaviour ([[frame]]), rebound to the existing locals.
	has_e2e := m.frames.e2e_on.len > 0
	has_secoc := m.frames.secoc_on.len > 0

	has_routes := m.routes.len > 0

	// Validate E2E byte positions against each frame's DLC (they index unsafe into
	// the frame's [64]u8 in the generated bridge).
	if has_e2e || has_secoc {
		db := candb.load_dbc_file(dbc) or {
			panic('protected frames need a DBC: load ${dbc}: ${err}')
		}
		for fk, _ in m.frames.e2e_on {
			dlc := dbc_dlc_of(db, fk) or {
				panic('e2e: frame "${fk}" is not a message in ${os.file_name(dbc)}')
			}
			cp := m.frames.e2e_crc[fk] or { 0 }
			np := m.frames.e2e_ctr[fk] or { 0 }
			if cp < 0 || cp >= dlc || np < 0 || np >= dlc || cp == np {
				panic('e2e ${fk}: crc_pos=${cp}, counter_pos=${np} must be distinct and within dlc=${dlc}')
			}
		}
		for fk, _ in m.frames.secoc_on {
			dlc := dbc_dlc_of(db, fk) or {
				panic('secoc: frame "${fk}" is not a message in ${os.file_name(dbc)}')
			}
			fp := m.frames.secoc_fresh[fk] or { 0 }
			mp := m.frames.secoc_mac[fk] or { 0 }
			ml := m.frames.secoc_maclen[fk] or { 0 }
			if (m.frames.secoc_key[fk] or { []u8{} }).len != 16 {
				panic('secoc ${fk}: key must be 16 bytes (AES-128)')
			}
			if ml < 1 || ml > 16 || fp < 0 || fp >= dlc || mp < 0 || mp + ml > dlc
				|| (fp >= mp && fp < mp + ml) {
				panic('secoc ${fk}: fresh_pos=${fp}, mac_pos=${mp}, mac_len=${ml} must be 1..16, fit within dlc=${dlc}, and not overlap')
			}
		}
	}


	// partition/thread/fb topology, rebound to the existing locals.
	// (m.part.fb_thread is read only by emit_manifest, straight from the model — no local rebind.)

	// --- telemetry: give every app partition + every bus(bridge) a scratch slot,
	//     remembering its core, so a generated tx can sum processor load by core
	//     and ship it as a CpuLoad CAN frame. Gated by an [telemetry] config block. ---
	mut telem_iface := '' // derived from the bus interface below
	mut telem_slot := map[string]int{}
	mut slot_core := []int{}

	// --- trace: the runtime-observability control/telemetry frames. Gated by a [trace]
	//     block; loom2v emits their symbolic DBC (arg 8) so blobly_net can decode/send them
	//     by name. Ids default to the docs/telemetry.md convention. The dump rides ISO-TP on
	//     record_id/dump_fc_id (not a decodable frame), so those are not DBC messages. ---
	// Each observability frame id is either a literal CAN id (used as-is — collision-free
	// allocation is the author's responsibility) or the NAME of a message in bus.dbc, resolved
	// to that message's id (and required to exist). Defaults are the docs/telemetry.md ids.
	// [trace] block -> the model (parse_trace). Rebound to the existing locals so the emit code
	// below is unchanged. (Step (a) of the parse->model->emit refactor.)

	// [target] baremetal: emit a single-core inline superloop instead of the host's
	// spawned partitions + osal. No threads, no osal (POSIX now_us/sleep_us don't
	// exist bare-metal); the timebase is board_now_us() and the loop paces to a fixed
	// tick. Requires all signals partition-local (no COM bus bridge).
	// [target] kind selects the on-target emitter: 'baremetal' is the single-core inline
	// superloop (P3c-0); 'threadx' (P3c-1) wraps the same FB/telemetry work in a real
	// ThreadX thread paced by tx_thread_sleep (the preemptive-RTOS target — see
	// examples/threadx_h735, the hand-written golden reference this generates).
	if m.target.on && m.has_external && !m.target.threadx {
		panic('loom2v: [target] baremetal does not support external/bus signals yet ' +
			'(every [[signal]] must be partition-local: from == to). The ThreadX target does — ' +
			'its comm thread services rx (phase 6b-2).')
	}
	// The ThreadX target's trace is the EXEC-CHANGE-HOOK model (trace_hooks.c captures every
	// real context switch + ISR into a ring), NOT the loom2v polled V-stack capture. So a
	// [trace] block on a threadx target does not engage the inline/multicore trace machinery
	// (trace_target excludes threadx below); it only tells the generated bus owner which
	// record_id to stream the ring on. The FB loop being a real ThreadX thread means the hooks
	// capture it for free — see the threadx run() below (phase 6b-1).
	// The threadx app thread opens the telemetry bus for its CAN channel, so the target needs
	// [telemetry] ENABLED, with a bus that actually exists (the schema makes all of that
	// optional in general, and only `driver.can` gets imported when m.telem.on).
	if m.target.threadx {
		mut bus_exists := false
		if busv := doc.value_opt('bus') {
			bus_exists = m.telem.bus in busv.as_map()
		}
		if !m.telem.on || m.telem.bus == '' {
			panic('loom2v: [target] kind="threadx" needs [telemetry] enabled with a bus — the app ' +
				'thread opens it for the CAN channel')
		}
		if !bus_exists {
			panic('loom2v: [target] kind="threadx": [telemetry].bus = "${m.telem.bus}" has no matching ' +
				'[bus.${m.telem.bus}]')
		}
	}

	// Single-core inline trace: exactly one (fb-bearing) partition, host, pinned to the trace
	// bus's core, and NO COM bus bridge — so one superloop owns the channel and drives capture +
	// cmd/rsp + dump + the HandlerStat heartbeat directly (no IOC, nothing else to schedule). A
	// bridge (external signals / ISO-TP / m.routes) or multiple cores need the comm-thread model,
	// not generated yet.
	single_part := if m.part.by_part.keys().len == 1 { m.part.by_part.keys()[0] } else { '' }
	has_bridge := m.has_external || m.isotp_conns.len > 0 || has_routes
	// ThreadX COM bridge (phase 6b-2): the target grows a bus-owning comm thread that services
	// rx (woken by the FDCAN Rx ISR) while the FB thread stays off CAN and publishes load via a
	// scratch cell. The comm thread is the generic bus owner — telemetry and the trace ring are
	// its first two producers, rx frames go to consumers — so NM/COM-tx slot in later as more of
	// the same. The lean first cut supports external RX signals (bus -> app), drained + counted
	// by the comm thread; external TX signals, ISO-TP, and m.routes are not generated yet.
	comm_thread_on := m.target.threadx && has_bridge
	// rx signals an FB reads flow bus -> comm(decode) -> target IOC pool cell -> FB input (6b-2b).
	// ioc_idx maps each such signal to its pool cell; visible to the comm emitter + handler glue.
	mut ioc_idx := map[string]int{}
	mut msg_ioc_idx := map[int]int{} // DBC id -> its (single) rx-read signal's IOC cell
	if comm_thread_on {
		if has_routes || m.isotp_conns.len > 0 {
			panic('loom2v: [target] kind="threadx" comm thread: routes / ISO-TP are not generated ' +
				'yet (phase 6b-2 lean cut = external rx signals only)')
		}
		// Which signals FB handlers read vs write. An rx signal READ by an FB flows through the
		// target IOC pool (6b-2b); an rx signal WRITTEN by an FB is a config error (an input isn't
		// written). Everything else external is still deferred (rejected below).
		mut read_count := map[string]int{} // how many FB handlers read each signal
		mut written_count := map[string]int{} // how many FB handlers write each signal
		for fb in ecumodel.toml_arr(doc, 'fb') {
			for h in (fb.as_map()['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hm := h.as_map()
				for r in (hm['reads'] or { toml.Any([]toml.Any{}) }).array() {
					read_count[r.string()]++
				}
				for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
					written_count[w.string()]++
				}
			}
		}
		// How many rx signals READ by FBs each DBC message carries (the lean whole-frame decode
		// serves one per message; more need the per-signal codec).
		mut msg_read_sigs := map[string]int{}
		for sn in m.sig_names {
			s := m.sig_of[sn] or { continue }
			if s.rx && read_count[sn] > 0 {
				msg_read_sigs[s.dbc_msg]++
			}
		}
		for sname in m.sig_names {
			si := m.sig_of[sname] or { continue }
			if si.external && !si.rx {
				// external TX signal (app -> bus): an FB writes it into a target IOC cell, the comm
				// thread reads the cell each tx period, encodes, and sends. Mirror of rx; same lean
				// constraints so the whole-frame encode + SPSC pool stay correct.
				if written_count[sname] != 1 {
					panic('loom2v: [target] kind="threadx" comm thread: external TX signal "${sname}" ' +
						'must be written by exactly one FB (got ${written_count[sname]}) — the IOC cell is ' +
						'single-writer (SPSC); multiple producers would race the writer slot')
				}
				if read_count[sname] > 0 {
					panic('loom2v: [target] kind="threadx" comm thread: external TX signal "${sname}" is ' +
						'also read by an FB — a local consumer of a to-bus signal is not generated yet')
				}
				if !si.dbc_trivial {
					panic('loom2v: [target] kind="threadx" comm thread: TX signal "${sname}" is not a plain ' +
						'unsigned little-endian 32-bit value at bit 0 (factor 1, offset 0); other layouts ' +
						'need the DBC codec on target — not generated yet')
				}
				if si.dbc_ext || si.dbc_id > 0x7ff {
					panic('loom2v: [target] kind="threadx" comm thread: TX signal "${sname}" DBC message is ' +
						'extended (29-bit) — the classic FDCAN backend sends 11-bit frames; use a standard id')
				}
				if si.bus != m.telem.bus {
					panic('loom2v: [target] kind="threadx" comm thread: TX signal "${sname}" is on bus ' +
						'"${si.bus}", but the comm thread owns only [telemetry].bus "${m.telem.bus}"')
				}
				if (m.frames.e2e_on[si.dbc_msg] or { false }) || (m.frames.secoc_on[si.dbc_msg] or { false }) {
					panic('loom2v: [target] kind="threadx" comm thread: TX message "${si.dbc_msg}" has ' +
						'E2E / SecOC, but the lean encode only packs the raw value — not generated yet')
				}
				tx_m := m.frames.tx_mode[si.dbc_msg] or { 'cyclic' }
				if tx_m != 'cyclic' {
					panic('loom2v: [target] kind="threadx" comm thread: TX message "${si.dbc_msg}" tx.mode ' +
						'"${tx_m}" is not generated — the comm producer sends purely cyclically (no ' +
						'event/mixed/triggered or min_delay_ms); use mode = "cyclic"')
				}
				if si.dbc_dlc > 8 {
					panic('loom2v: [target] kind="threadx" comm thread: TX message "${si.dbc_msg}" DLC ' +
						'${si.dbc_dlc} > 8 (CAN-FD sized), but the classic FDCAN backend rejects len > 8; ' +
						'use a <= 8-byte frame')
				}
				ioc_idx[sname] = ioc_idx.len
				continue
			}
			if !si.rx {
				continue
			}
			if written_count[sname] > 0 {
				panic('loom2v: [target] kind="threadx" comm thread: rx signal "${sname}" is WRITTEN by an ' +
					'FB handler — an rx (bus -> app) signal is an input; drop the handler write')
			}
			if si.bus != m.telem.bus {
				panic('loom2v: [target] kind="threadx" comm thread: rx signal "${sname}" is on bus ' +
					'"${si.bus}", but the comm thread owns only [telemetry].bus "${m.telem.bus}" — a per-bus ' +
					'comm owner is not generated yet (phase 6b-2 lean cut = one bus)')
			}
			if si.dbc_ext || si.dbc_id > 0x7ff {
				panic('loom2v: [target] kind="threadx" comm thread: rx signal "${sname}" DBC message is ' +
					'extended (29-bit${if si.dbc_ext { ' — the EFF flag is set' } else { '' }}), but the ' +
					'classic FDCAN backend delivers only 11-bit standard frames — use a standard id')
			}
			if (m.frames.rx_timeout_us[si.dbc_msg] or { 0 }) > 0 || (m.frames.e2e_on[si.dbc_msg] or { false })
				|| (m.frames.secoc_on[si.dbc_msg] or { false }) {
				panic('loom2v: [target] kind="threadx" comm thread: rx message "${si.dbc_msg}" has an RX ' +
					'deadline / E2E / SecOC, but the lean comm thread only counts raw rx.id matches — ' +
					'those COM checks are not generated yet (phase 6b-2b)')
			}
			// rx signal an FB reads -> flows through a target IOC pool cell. The lean decode is a
			// whole-frame u32 into sig_t.a, and the pool is one-value-per-frame, so reject the
			// layouts/topologies it can't reproduce rather than mis-decode. (Multiple FB *readers*
			// are fine: the comm thread is the single writer, and every FB runs on the ONE generated
			// app thread — a single reader CONTEXT — so the reads are sequential, never a concurrent
			// race on the SPSC reader slot. A cross-thread fan-out guard is for the multi-thread phase.)
			if read_count[sname] > 0 {
				if !si.dbc_trivial {
					panic('loom2v: [target] kind="threadx" comm thread: rx signal "${sname}" read by an FB ' +
						'is not a plain unsigned little-endian 32-bit value at bit 0 (factor 1, offset 0); ' +
						'other layouts need the DBC codec on target (phase 6b-2b+) — not generated yet')
				}
				if si.has_valid {
					panic('loom2v: [target] kind="threadx" comm thread: rx signal "${sname}" has a `valid` ' +
						'field, but the lean IOC read only sets the value — an FB would see valid=false ' +
						'forever; a freshness-carrying transport is not generated yet')
				}
				if (msg_read_sigs[si.dbc_msg] or { 0 }) > 1 {
					panic('loom2v: [target] kind="threadx" comm thread: DBC message "${si.dbc_msg}" carries ' +
						'${msg_read_sigs[si.dbc_msg]} rx signals read by FBs, but the lean whole-frame decode ' +
						'publishes one per frame — per-signal decode needs the codec (phase 6b-2b+)')
				}
				ioc_idx[sname] = ioc_idx.len
				// Key the publish off the READ signal's DBC id, not the de-duped rx_sigs
				// representative (which may be an un-read signal that happens to sort first).
				msg_ioc_idx[si.dbc_id] = ioc_idx[sname]
			}
		}
		if ioc_idx.len > 4 {
			panic('loom2v: [target] kind="threadx" comm thread: ${ioc_idx.len} rx-to-FB signals need IOC ' +
				'cells, but the pool (comm_glue.c IOC_POOL_N) has 4 — raise IOC_POOL_N or reduce signals')
		}
	}
	// Which m.buses run a COM bridge (an external signal, an ISO-TP conn, or a route touches them).
	// P3b traces each bridge as a `comm_<bus>` thread; the DIFFERENT-bus case (trace rides a bus with
	// no bridge) reuses the P3a owner cleanly, the SAME-bus case (the bridge owns the trace channel)
	// is the follow-up — docs/trace-multicore.md §4.3.
	// A bus runs a bridge LOOP (a comm thread) if it originates COM work — external rx/tx signals,
	// an ISO-TP conn, or a route it forwards FROM. (A route's dest bus only receives forwarded
	// frames on its channel; it gets no loop of its own — matches the bus_names set below.)
	mut bridge_buses := map[string]bool{}
	for _, si in m.sig_of {
		if si.external {
			bridge_buses[si.bus] = true
		}
	}
	for c in m.isotp_conns {
		bridge_buses[c.bus] = true
	}
	for r in m.routes {
		bridge_buses[r.from_bus] = true
	}
	// The trace bus must carry NO COM at all for the different-bus path — not even route-forwarded
	// tx (which would share its channel with the trace handshake). Flag a route dest too.
	// P3a: each core's polled superloop is one cooperative thread — no preemptive context switches
	bridge_bus_list := []string{} // sorted bridge m.buses — stable comm-thread numbering + ring order

	if m.telem.on {
		if bc := doc.value('bus').as_map()[m.telem.bus] {
			telem_iface = (bc.as_map()['interface'] or { toml.Any('') }).string()
		}
		mut tparts := m.part.by_part.keys()
		tparts.sort()
		for tp in tparts {
			if slot_core.len < 16 { // scratch holds 16 u64s
				telem_slot['p:${tp}'] = slot_core.len
				slot_core << (m.part.core_of[tp] or { 0 })
			}
		}
		mut tbuses := m.bus_core.keys()
		tbuses.sort()
		for tb in tbuses {
			if slot_core.len < 16 {
				telem_slot['b:${tb}'] = slot_core.len
				slot_core << (m.bus_core[tb] or { 0 })
			}
		}
	}


	mp, mg := emit_module_headers(m, ecu, comm_thread_on, trace_host)
	mut ports := mp.clone()
	mut glue := mg.clone()


	// The platform producers (telemetry, trace) the shared emitters iterate — so no emitter names a
	// specific capability for its partition-loop injection. NM / COM-tx join this list later.
	producers := [Producer(TelemProducer{
		on:        m.telem.on
		slot:      telem_slot.clone()
		id:        m.telem.id
		detail_id: m.telem.detail_id
	})]

	fb_ports, fb_glue, all_regs := emit_handlers(m, producers, ioc_idx, trace_host)
	ports << fb_ports
	glue << fb_glue

	// --- generated COM bus bridge(s) — emitted by emit_bridges ---
	bridge_glue, bnames, bus_dests := emit_bridges(m, comm_thread_on, producers)
	glue << bridge_glue
	mut bus_names := bnames.clone()

	// --- telemetry tx: sum per-partition load by core -> CpuLoad frame on the bus (emit_partition_telem) ---
	glue << emit_partition_telem(m, telem_iface, slot_core, trace_host)


	bus_names.sort()
	// A raw [[route]] to an otherwise-unused bus makes that bus a channel arg (it's forwarded to the
	// origin bridge's spawn) but NOT a bridge of its own, so it never entered bus_names. run() still
	// needs a Channel param for it, appended after bus_names (sorted) so the signature stays stable —
	// existing configs, whose route dests also tx (already in bus_names), are unaffected.
	mut extra_dest_buses := []string{}
	for b in bus_names {
		for d in bus_dests[b] or { []string{} } {
			if d !in bus_names && d !in extra_dest_buses {
				extra_dest_buses << d
			}
		}
	}
	extra_dest_buses.sort()
	if m.target.on {
		glue << emit_run_target(m, doc, all_regs, telem_iface, comm_thread_on, ioc_idx, msg_ioc_idx, producers)
	} else if trace_host {
		glue << emit_run_trace_host(m, all_regs, telem_iface, single_part)
	} else {
		glue << emit_run_host(m, telem_iface, bus_names, bus_dests, extra_dest_buses)
	}

	os.write_file(args[3], signals.join('\n') + '\n') or { panic('write ${args[3]}: ${err}') }
	os.write_file(args[4], ports.join('\n') + '\n') or { panic('write ${args[4]}: ${err}') }
	os.write_file(args[5], glue.join('\n') + '\n') or { panic('write ${args[5]}: ${err}') }

	// --- trace manifest (optional arg 6): the identity tables blobly_net loads to resolve
	//     an entity_id back to a name (emit_manifest). ---
	if args.len >= 7 {
		man := emit_manifest(m, doc, ecu, comm_thread_on, single_part, bridge_bus_list)
		os.write_file(args[6], man.join('\n') + '\n') or { panic('write ${args[6]}: ${err}') }
	}

	eprintln('loom2v: ${m.sig_names.len} signals (${bus_names.len} bus bridge), ${m.isotp_conns.len} isotp, ${m.part.by_part.len} partition(s)')
}

// did_signal_encode emits the big-endian write of a live signal value into a
// DID's data buffer (per the signal's value-field type).
fn did_signal_encode(tp string, idx int, expr string, val_type string) string {
	d := 'st.uds_${tp}.dids[${idx}]'
	return match val_type {
		'u16' {
			'\t\t${d}.data[0] = u8(${expr} >> 8)\n\t\t${d}.data[1] = u8(${expr})\n\t\t${d}.len = 2'
		}
		'u32' {
			'\t\t${d}.data[0] = u8(${expr} >> 24)\n\t\t${d}.data[1] = u8(${expr} >> 16)\n\t\t${d}.data[2] = u8(${expr} >> 8)\n\t\t${d}.data[3] = u8(${expr})\n\t\t${d}.len = 4'
		}
		'bool' {
			'\t\t${d}.data[0] = if ${expr} { u8(1) } else { u8(0) }\n\t\t${d}.len = 1'
		}
		else {
			'\t\t${d}.data[0] = u8(${expr})\n\t\t${d}.len = 1'
		}
	}
}

// byte16_lit renders 16 bytes as a V fixed-array literal `[u8(0x..), 0x.., ...]!`
// (zero-padded), for a generated secoc.new_key(...) call.
fn byte16_lit(b []u8) string {
	mut parts := []string{}
	for i in 0 .. 16 {
		v := if i < b.len { b[i] } else { u8(0) }
		parts << if i == 0 { 'u8(0x${v.hex()})' } else { '0x${v.hex()}' }
	}
	return '[${parts.join(', ')}]!'
}

// parse_hex turns "01 0A FF" into bytes.
fn parse_hex(s string) []u8 {
	mut out := []u8{}
	for part in s.split(' ') {
		if part != '' {
			out << hexbyte(part)
		}
	}
	return out
}

fn hexbyte(s string) u8 {
	mut v := 0
	for c in s {
		v *= 16
		if c >= `0` && c <= `9` {
			v += int(c - `0`)
		} else if c >= `a` && c <= `f` {
			v += int(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			v += int(c - `A`) + 10
		}
	}
	return u8(v)
}

// dbc_dlc_of returns the DLC (byte length) of the message whose snake-name is `key`.
fn dbc_dlc_of(db candb.Database, key string) ?int {
	for m in db.messages {
		if snake(m.name) == key {
			return int(m.dlc)
		}
	}
	return none
}

// dbc_id_of returns the CAN id of the message whose snake-name is `key`.
fn dbc_id_of(db candb.Database, key string) ?int {
	for m in db.messages {
		if snake(m.name) == key {
			return int(m.id)
		}
	}
	return none
}

// dbc_ext_of returns whether the message whose snake-name is `key` is an extended (29-bit)
// frame. candb strips the EFF marker into Message.ext and leaves a stripped id, so an
// extended frame can have id <= 0x7FF — callers must test this flag, not just the id.
fn dbc_ext_of(db candb.Database, key string) ?bool {
	for m in db.messages {
		if snake(m.name) == key {
			return m.ext
		}
	}
	return none
}

// dbc_signal_trivial reports whether the DBC signal named `signame` is a plain unsigned
// little-endian (Intel) 32-bit value starting at bit 0 with factor 1 / offset 0 — the ONLY
// layout the lean ThreadX comm-thread decode (a whole-frame u32) reproduces exactly. Any
// other layout (8/16-bit, a non-zero start bit, scaling, signed, Motorola) needs the DBC
// codec and is rejected on that path rather than silently mis-decoded.
fn dbc_signal_trivial(db candb.Database, signame string) ?bool {
	for m in db.messages {
		for s in m.signals {
			if s.name == signame {
				return s.start_bit == 0 && s.length == 32 && !s.is_signed && s.factor == 1.0
					&& s.offset == 0.0 && s.byte_order == candb.ByteOrder.little_endian
			}
		}
	}
	return none
}

// dbc_message_of returns snake(message name) of the DBC message carrying `sig`.
fn dbc_message_of(db candb.Database, signame string) ?string {
	for m in db.messages {
		for s in m.signals {
			if s.name == signame {
				return snake(m.name)
			}
		}
	}
	return none
}

fn provenance(name string, sig_of map[string]SigInfo) string {
	s := sig_of[name] or { return '\t// signal "${name}"' }
	if s.local {
		return '\t// signal "${name}" — local cell in partition "${s.from}"'
	}
	return '\t// signal "${name}" — ch, transport ${s.transport}, ${s.from} -> ${s.to}'
}

fn acquire_fn(tr string) string {
	return match tr {
		'seqlock' { 'ioc_read' }
		'triple' { 'ioc_acquire' }
		else { 'ioc_acquire2' }
	}
}

fn publish_fn(tr string) string {
	return match tr {
		'seqlock' { 'ioc_write' }
		'triple' { 'ioc_publish' }
		else { 'ioc_publish2' }
	}
}

fn snake(name string) string {
	mut out := []u8{}
	for i, c in name {
		is_upper := c >= `A` && c <= `Z`
		if is_upper && i > 0 {
			prev := name[i - 1]
			if (prev >= `a` && prev <= `z`) || (prev >= `0` && prev <= `9`) {
				out << `_`
			}
		}
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			out << c
		} else if is_upper {
			out << c + 32
		} else {
			out << `_`
		}
	}
	return out.bytestr()
}
