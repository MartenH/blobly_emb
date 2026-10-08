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
//   v run tools/loom2v <ecu.toml> <bus.dbc> <signals_out> <ports_out> <glue_out>
// (the DIRECTORY, not gen.v alone — loom2v is split across gen_*.v sibling files in
// `module main`; run from a freestanding example with its own v.mod so module names are short)
module main

import os
import toml
import tools.candb
import tools.ecumodel
import tools.cfgschema
import comm.uds
import comm.fault

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
	val_field string // the signal's value field (its first field that is not RxStatus / `valid`, nor a received signal's `lost`)
	val_type  string // its V type
	// Receive status (docs/diagnostics.md §3.2): a field of type RxStatus — on a bus-rx signal
	// it must be named `status`, and the bridge owns it — and, on a bus-rx signal whose frame is
	// E2E-protected, a `lost` counter of frames the sequence showed missing (u16 / u32, wraps).
	has_status bool
	lost_type  string // '' = no lost counter
	dbc_msg   string // snake(DBC message name) carrying this signal (if external)
	dbc_id    int    // the DBC message's CAN id (if external) — resolved once at parse time
	dbc_dlc   int    // the DBC message's DLC (if external)
	dbc_ext   bool   // the DBC message is an extended (29-bit) frame (EFF flag) — id may be stripped
	dbc_trivial bool // the DBC signal is a plain unsigned LE 32-bit value at bit 0 (factor 1, offset 0)
	dbc_lane_issue string // '' or why this signal's DBC MESSAGE cannot carry the lane encode
	// (every SG must sit alone in a 32-bit lane: start%32==0, <=32 bits, unsigned LE,
	// factor 1/offset 0) — the lane writer fills WHOLE 4-byte lanes, so any other layout
	// means an unrelated SG gets overwritten silently (codex #211 r5)
	dbc_lanes []candb.Signal // per 32-bit lane of the message, the DBC signal that owns it (lane 0 is
	// the signal itself; a name of '' = none there) — the target producers encode through its range
	dbc_init []u8 // a sent signal's DBC message before anything is published: every signal at its
	// initial value (candb init_payload, REQ-COM-011) — the bytes every emitter starts the frame with
	fields    []SigField // the signal's fields in declaration order (for the `sig` struct emit)
	persist   string // '' | 'now' | 'shutdown' — restored + journaled by the platform
	nvm_id    u16 // explicit schema-identity pin (0 = derive by hash); see gen_nvm.v
	remote    bool // `from` is a partition on ANOTHER image (external/imaged) — the crossing
	// rides an xioc slot (gen_xcore.v); derived in build_model, never configured. SMP note:
	// a coherent single-image target would derive `false` here and use ordinary IOC.
	io_in  bool // `from` is the io endpoint class (docs/io.md): the io thread publishes it
	io_out bool // `to` is the io endpoint class: the io thread acquires + applies it
	wide   bool // remote signal that outgrows the {a,b} pair cell (fields > 2, non-u32 types,
	// or a `valid` field): rides a wide xioc_n channel, one u32 lane per field
	// (docs/multi-image.md "Wide remote signals", REQ-INV-006)
}

// SigField is one field of a signal's payload struct (name + V type), in declaration order.
struct SigField {
	name string
	typ  string
}

// IsotpConn is the node's [isotp] connection (ISO 15765-2): the ONE diagnostic server's transport
// on CAN. The server itself — S3, 0x27, the service table — is [uds] (UdsCfg, gen_diag.v).
struct IsotpConn {
	name          string // 'diag': the generated connection's identifiers (st.conn_diag, diag_refresh_diag)
	bus           string
	rx_id         int
	tx_id         int
	bs            int
	stmin         int
	functional_id int // 0 = no functional requests on this connection
}

// DidCfg is one [[did]]: constant bytes, a writable RAM cell, and/or a live signal.
struct DidCfg {
	id             int
	bytes          []u8
	writable       bool
	signal         string
	read_sessions  u8 // uds.in_* mask; 0 = every session
	write_sessions u8
	read_security  u8 // the 0x27 level required; 0 = none
	write_security u8
	param          string // the [[param]] this DID codes (0x2E) and reads back (0x22); '' = none
	param_status   bool   // the parameters' status: one byte per [[param]] (comm/param status_*)
	tx_saturations bool   // the count of sent values com.encode_raw saturated: a u32, big-endian
}

// Route is one [[route]] on a gateway. A RAW (frame) route forwards a PDU unchanged
// (to_id == 0 keeps the source id). A SIGNAL route (signal != '') decodes the named
// signal from from_frame on the source bus and re-encodes it into to_frame on the
// destination bus (a different id/layout) — the codec fns for both frames are in
// dbc_gen.v (generated per DBC message), so the forwarder just calls _phys then _set.
struct Route {
mut:
	from_bus   string
	from_frame string
	from_id    int
	from_dlc   int
	to_bus     string
	to_id      int
	signal     string // set => SIGNAL route (decode + re-encode); '' => raw frame route
	to_frame   string // SIGNAL route: the destination DBC frame to re-encode into
	to_dlc     int
	from_cyc   int // source frame GenMsgCycleTime (ms) — the freshness deadline base
	to_cyc     int // destination frame GenMsgCycleTime (ms) — the re-emit cadence
	to_bit     int // SIGNAL route: the routed signal's start bit in the destination frame
	to_len     int // SIGNAL route: the routed signal's bit length in the destination frame
	from_ext   bool // the source frame is an extended (29-bit) id — the rx match checks rx.ext
	to_ext     bool // the destination on-wire id width (raw: = from_ext; signal: the dest frame)
	raw_ident  bool // src/dst frames are byte-layout identical — forward by raw copy + id remap
	dst_sg     candb.Signal // SIGNAL route: the destination signal, whose range the re-encode holds to
	// (the ThreadX gateway comm thread forwards these on the target without a decode/re-encode
	//  codec; a route whose layouts DIFFER stays host-only until on-target transcode lands)
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
	// the E2E-owned reception timeout (REQ-E2E-002), read for received frames only. A DBC's
	// E2ETimeout lands here for a frame this ECU only sends too, where it is unused;
	// e2e_timeout_authored says which ones ecu.toml set, the only kind refused on a sent frame
	e2e_timeout_us map[string]int
	e2e_timeout_authored map[string]bool
	e2e_timeout_bad map[string]string // a DBC E2ETimeout that is not a number of ms, by frame
	secoc_on      map[string]bool
	secoc_id      map[string]int
	secoc_fresh   map[string]int
	secoc_mac     map[string]int
	secoc_maclen  map[string]int
	secoc_key     map[string][]u8
	frame_bus     map[string]string // snake(name) -> the [[frame]].bus it was authored on
}

// e2e_here / secoc_here: protection applies to a frame ONLY on the bus its [[frame]]
// block declared. FrameCfg is name-keyed, so a route to the same frame NAME on a
// DIFFERENT bus must NOT inherit this bus's profile (that would stamp the wrong
// CRC/MAC onto a frame whose wire contract never asked for it).
fn (f FrameCfg) e2e_here(frame string, bus string) bool {
	return (f.e2e_on[frame] or { false }) && (f.frame_bus[frame] or { '' }) == bus
}

fn (f FrameCfg) secoc_here(frame string, bus string) bool {
	return (f.secoc_on[frame] or { false }) && (f.frame_bus[frame] or { '' }) == bus
}

// parse_signals parses [[signal]] into the model: sig_of (with each signal's fields in
// declaration order), sig_names, and has_external. External signals are then resolved against
// bus.dbc (message id/dlc/ext/trivial). Value field = the single non-"valid" field.
// parse_nvm_id: range-check BEFORE narrowing — nvm_id = 65536 must fail, not
// silently become 0 (= auto-hash) through the u16 cast.
// toml_int: an integer key read WHOLE (i64) and held to [lo, hi] before anything narrows it —
// the one reader for ids and other bounded integers. toml.Any.int() truncates to 32 bits, and a
// u16 / u32 cast afterwards truncates again, so 0x10110 read through them was the DID 0x0110 (codex
// on #376). Absent = `def`; a non-integer is refused, never read as 0.
fn toml_int(m map[string]toml.Any, key string, def i64, lo i64, hi i64, what string) int {
	v := m[key] or { return int(def) }
	if v !is i64 {
		panic('loom2v: ${what} ${key} must be an integer')
	}
	n := v.i64()
	if n < lo || n > hi {
		panic('loom2v: ${what} ${key} = 0x${n.hex()} is out of range (0x${lo.hex()}..0x${hi.hex()})')
	}
	return int(n)
}

// schema_key: an ecu.toml key's row in THE schema (tools/cfgschema) — where a leaf check reads its
// bound or its values, so a limit is stated once
fn schema_key(ctx string, name string) cfgschema.Key {
	return cfgschema.ecu.key(ctx, name)
}

// schema_int: toml_int bounded by the key's schema range (a row with no range is a caller defect)
fn schema_int(m map[string]toml.Any, ctx string, key string, def i64, what string) int {
	k := schema_key(ctx, key)
	if !k.ranged || k.or_zero {
		panic('loom2v: schema row ${ctx}.${key} is not a plain range — schema_int cannot bound it')
	}
	return toml_int(m, key, def, k.min, k.max, what)
}

fn parse_nvm_id(name string, v int) u16 {
	k := schema_key('signal', 'nvm_id')
	if !k.in_range(v) {
		panic('ecu.toml: signal "${name}" nvm_id = ${v} is out of range (0 = auto, 1..${k.max} = pin)')
	}
	return u16(v)
}

fn parse_signals(doc toml.Doc, dbc string, buses map[string]bool, eth string) (map[string]SigInfo, []string, bool, bool) {
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
		// io is a RESERVED endpoint class (docs/io.md), never a bus or partition —
		// without this an io endpoint would fall through as a phantom partition.
		// Its transport is DERIVED, never configured: same-core consumer -> triple
		// (wait-free both sides); cross-core (xioc) arrives with the target phase
		// (checked in build_model).
		io_in := from == 'io'
		io_out := to == 'io'
		mut transport := (m['transport'] or { toml.Any('double') }).string()
		if io_in || io_out {
			transport = 'triple'
		}

		fields := (m['fields'] or { toml.Any(map[string]toml.Any{}) }).as_map()
		if fields.len == 0 {
			panic('ecu.toml: signal "${name}" needs `fields` (e.g. fields = { kph = "u16" })')
		}
		mut val_field := ''
		mut val_type := ''
		mut has_status := false
		mut lost_type := ''
		mut sfields := []SigField{}
		for fname, ftype in fields {
			typ := ftype.string()
			sfields << SigField{
				name: fname
				typ:  typ
			}
			if typ == 'RxStatus' {
				has_status = true
				if from_bus && fname != 'status' {
					panic('ecu.toml: signal "${name}" is received from ${from}: its RxStatus field must be named `status` (the bridge fills it)')
				}
			}
			// on a signal received from a bus the bridge owns these three names; elsewhere they
			// are ordinary fields an FB writes (e.g. forwarding a status it read)
			if from_bus && fname == 'valid' {
				panic('ecu.toml: signal "${name}" has a `valid` field — a received signal carries `status = "RxStatus"` instead (never_received / ok / timeout / integrity; docs/diagnostics.md §3.2)')
			}
			if from_bus && fname == 'status' && typ != 'RxStatus' {
				panic('ecu.toml: signal "${name}" field `status` is "${typ}" — on a received signal it is the bridge-owned "RxStatus"')
			}
			if from_bus && fname == 'lost' {
				if typ != 'u16' && typ != 'u32' {
					panic('ecu.toml: signal "${name}" field `lost` is "${typ}" — the E2E lost-frame counter is u16 or u32')
				}
				lost_type = typ
				continue
			}
			if typ != 'RxStatus' && fname != 'valid' && val_field == '' {
				val_field = fname
				val_type = typ
			}
		}
		if from_bus && val_field == '' {
			panic('ecu.toml: signal "${name}" is received from ${from} but has no value field — `status` and `lost` describe a value; add one (e.g. kph = "u16")')
		}

		sig_of[name] = SigInfo{
			name:      name
			transport: transport
			persist:   (m['persist'] or { toml.Any('') }).string()
			nvm_id:    parse_nvm_id(name, schema_int(m, 'signal', 'nvm_id', 0, 'signal "${name}"'))
			from:      from
			to:        to
			local:     from == to
			external:  external
			bus:       if from_bus { from } else { to }
			rx:        from_bus
			val_field: val_field
			val_type:  val_type
			has_status: has_status
			lost_type:  lost_type
			fields:    sfields
			io_in:     io_in
			io_out:    io_out
		}
		sig_names << name
	}
	// Map each external signal to its DBC message (so the bridge can name the generated codec
	// fns / id / dlc). External CAN signals must be in the DBC; eth signals have
	// no DBC — their layout is DERIVED from the declarations (docs/someip.md).
	mut has_can_ext := false
	for sname in sig_names {
		si := sig_of[sname] or { continue }
		if si.external && si.bus != eth {
			has_can_ext = true
		}
	}
	if has_can_ext {
		db := candb.load_dbc_file(dbc) or {
			panic('external signals need a DBC: load ${dbc}: ${err}')
		}
		for sname in sig_names {
			mut si := sig_of[sname] or { continue }
			if !si.external || si.bus == eth {
				continue
			}
			si.dbc_msg = dbc_message_of(db, sname) or {
				panic('signal "${sname}" has a bus endpoint but is not in ${os.file_name(dbc)}')
			}
			si.dbc_id = dbc_id_of(db, si.dbc_msg) or { 0 }
			si.dbc_dlc = dbc_dlc_of(db, si.dbc_msg) or { 8 }
			si.dbc_ext = dbc_ext_of(db, si.dbc_msg) or { false }
			si.dbc_trivial = dbc_signal_trivial(db, sname) or { false }
			mut fwidths := []int{}
			for f in si.fields {
				fwidths << match f.typ {
					'u32' { 32 }
					'u16' { 16 }
					'u8' { 8 }
					'bool' { 1 }
					else { 32 }
				}
			}
			si.dbc_lane_issue = dbc_msg_lane_issue(db, sname, si.fields.len, fwidths)
			si.dbc_lanes = dbc_lanes(db, sname, si.fields.len)
			if !si.rx {
				// a value this node sends is held to its range (REQ-COM-010): the range must hold one
				sg := si.dbc_lanes[0] or { candb.Signal{} }
				rr := sg.raw_range() or { panic('loom2v: sent signal "${sname}": ${err}') }
				if rr.note != '' {
					panic('loom2v: sent signal "${sname}": ${rr.note} in ${os.file_name(dbc)} — a sent value is held to its signal\'s range, so the range must be one a value can be sent in (docs/communication.md)')
				}
				msg := dbc_msg_named(db, si.dbc_msg) or {
					panic('loom2v: sent signal "${sname}": no DBC message "${si.dbc_msg}" in ${os.file_name(dbc)}')
				}
				si.dbc_init = msg.init_payload() or {
					panic('loom2v: sent signal "${sname}": ${err} in ${os.file_name(dbc)} (docs/communication.md "Initial values")')
				}
			}
			sig_of[sname] = si
		}
	}
	return sig_of, sig_names, has_external, has_can_ext
}

// emit_signals generates the `sig` module — one struct per signal, fields in declaration order —
// from the model. (Emit is now separate from the parse that built sig_of.)
fn emit_signals(sig_of map[string]SigInfo, sig_names []string, ecu string) []string {
	mut signals := []string{}
	signals << '// Code generated by tools/loom2v from ${os.file_name(ecu)} — DO NOT EDIT.'
	signals << 'module sig'
	if sig_names.any((sig_of[it] or { SigInfo{} }).fields.any(it.typ == 'RxStatus')) {
		signals << ''
		signals << '// RxStatus: what the bridge last learned about a received signal (docs/diagnostics.md'
		signals << '// §3.2). The ZERO value is never_received, so a signal nothing has published yet — and a'
		signals << '// freestanding image, where no initialiser runs — reads as not-yet-received, never healthy.'
		signals << 'pub enum RxStatus as u8 {'
		signals << '\tnever_received // no good frame yet'
		signals << '\tok // the value came from a good frame'
		signals << '\ttimeout // the reception deadline passed (silence is the newest fact)'
		signals << '\tintegrity // the newest frame failed its E2E CRC or its SecOC check'
		signals << '}'
	}
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
	// external = not part of THIS image: the partition's code lives elsewhere — hand-written
	// (external = true) or emitted by the multi-image pass (image = "<dir>"). It still
	// participates in IDENTITY — manifest rows, global handler ids — but the owner image emits
	// no code for it, and it is excluded from every local derivation (comm priority, thread
	// counts, stat labels).
	external map[string]bool
	// image = the directory a GENERATED satellite image is emitted into (relative to the
	// example dir), keyed by partition. Implies external for the owner image.
	image map[string]string
}

// parse_buses returns the declared buses (endpoint names that mean "external / on the wire")
// and each bus's core.
// parse_routes parses [[route]] (raw-PDU gateway: forward a frame bus->bus, no decode) and
// resolves each from-frame to its DBC id (routes need a DBC).
// validate_route_cores enforces REQ-TOPO-010's cross-core half. A route whose buses sit on
// different cores cannot use the same-core mechanism (the source bridge holding the destination
// channel — impossible across images), so:
//   - a FRAME route is a hard error: a raw PDU (id + flags + up to 64 B) does not fit a signal
//     cell, and carrying it whole is the bulk transport's job (docs/bulk-transport.md). This is
//     the contract, not a gap.
//   - a SIGNAL route is the sanctioned crossing: its decoded physical value (one f64) rides an
//     IOC channel between the two comm owners — cfg2v allocates it (xr_*_ch), the source bridge
//     publishes on rx, the destination bridge acquires and composes/sends on ITS own channel.
fn validate_route_cores(routes []Route, bus_core map[string]int, bus_kind map[string]string) []Route {
	if msg := route_cores_error(routes, bus_core) {
		panic(msg)
	}
	if msg := route_kinds_error(routes, bus_kind) {
		panic(msg)
	}
	return routes
}

// route_kinds_error: routes are CAN machinery on BOTH ends. Same-core this was already
// enforced; the crossing must enforce it too, because the bridges skip eth buses entirely —
// an accepted eth-touching crossing would publish into a channel nobody acquires (CAN->eth)
// or emit a producer whose channel is never published (eth->CAN): silently dead traffic
// (codex #200). Pure and panic-free for routes_test.v.
fn route_kinds_error(routes []Route, bus_kind map[string]string) ?string {
	for r in routes {
		if (bus_kind[r.from_bus] or { '' }) == 'eth' || (bus_kind[r.to_bus] or { '' }) == 'eth' {
			what := if r.signal != '' { 'signal "' + r.signal + '"' } else { 'frame "' + r.from_frame + '"' }
			return 'route: ${what} touches an eth bus (${r.from_bus} -> ${r.to_bus}) — routes are ' +
				'CAN machinery; a SOME/IP event is declared as a [[signal]] on the eth bus, not routed'
		}
	}
	return none
}

// route_cores_error returns the first cross-core violation as a message, or none — pure and
// panic-free so routes_test.v can assert both messages in-process.
fn route_cores_error(routes []Route, bus_core map[string]int) ?string {
	for r in routes {
		fc := bus_core[r.from_bus] or { 0 }
		tc := bus_core[r.to_bus] or { 0 }
		if fc == tc {
			continue
		}
		if r.signal == '' {
			return 'route: frame "${r.from_frame}" ${r.from_bus}(core ${fc}) -> ${r.to_bus}(core ${tc}) ' +
				'crosses cores — a raw PDU does not fit a signal cell (REQ-TOPO-010). Route the ' +
				'signal instead, keep both buses on one core, or wait for the bulk transport ' +
				'(docs/bulk-transport.md).'
		}
	}
	return none
}

// crossing: the route's buses sit on different cores, so its value rides an IOC channel
// (REQ-TOPO-010) instead of the intra-thread same-core mechanism.
fn (r Route) crossing(bus_core map[string]int) bool {
	return (bus_core[r.from_bus] or { 0 }) != (bus_core[r.to_bus] or { 0 })
}

// xr_ch names the route crossing's IOC channel const (allocated by cfg2v in gen/ecu_gen.v —
// same `gen` module, so bridges reference it directly).
fn (r Route) xr_ch() string {
	return 'xr_${snake(r.to_bus)}_${snake(r.to_frame)}_${snake(r.signal)}_ch'
}

// fdcan_index_of strips the single FDCAN index digit ("can0" -> "0") the driver's
// blob_can_open reads (name[0]-'0'). loom2v already validated the telem bus this way; a
// gateway's route buses are validated the same when the extra channels are opened.
// frame_len_refusal: why a frame of `dlc` bytes cannot ride a CAN bus that is `fd` (or not) — none
// when it can. The ONE statement of the rule every frame goes through before any path splits (a
// signal's frame, TX or RX, checked or lean, and both ends of a route): a classic bus carries at
// most 8 bytes, and on an FD bus only the lengths a DLC expresses arrive — the FDCAN receiver
// reports the canonical wire length (9 bytes arrive as 12) and every matcher compares rx.len to
// the literal DLC, so either mismatch is a frame that is never sent or never matched.
fn frame_len_refusal(dlc int, fd bool) ?string {
	if !fd && dlc > 8 {
		return '${dlc} bytes on a classic bus (fd = false carries at most 8)'
	}
	if fd && !fd_len_ok(dlc) {
		return '${dlc} bytes — not a representable CAN-FD length (0..8, 12, 16, 20, 24, 32, 48, 64)'
	}
	return none
}

// fd_len_ok: is `n` a length CAN-FD can carry (the DLC set the driver's len_to_dlc maps 1:1)?
fn fd_len_ok(n int) bool {
	return n <= 8 || n == 12 || n == 16 || n == 20 || n == 24 || n == 32 || n == 48 || n == 64
}

fn fdcan_index_of(bus string) string {
	for c in bus {
		if c >= `0` && c <= `9` {
			return c.ascii_str()
		}
	}
	return '0'
}

// gw_var names the comm thread's channel variable for a bus: the telem bus reuses the
// existing `ch`; every other route bus gets `ch_<bus>` (opened alongside it).
fn gw_var(bus string, telem_bus string) string {
	return if bus == telem_bus { 'ch' } else { 'ch_${snake(bus)}' }
}

// gateway_extra_buses lists the route buses OTHER than the telem bus (which is already
// `ch`), in first-seen order across the routes — deterministic, so the generated channel
// set is stable across runs.
fn gateway_extra_buses(m Model) []string {
	mut out := []string{}
	mut seen := map[string]bool{}
	seen[m.telem.bus] = true
	for r in m.routes {
		for b in [r.from_bus, r.to_bus] {
			if !seen[b] {
				seen[b] = true
				out << b
			}
		}
	}
	return out
}

// gateway_forward_arms emits the forwarders for every route whose SOURCE is `src_bus`, to be
// injected into that channel's rx-drain loop. Each arm matches the source frame (id + dlc +
// id-width) and sends it under the destination id on the destination channel, tx_ready-gated: a
// FRAME route forwards the payload as it is; a SIGNAL route re-encodes its value through the one
// send encode (route_reencode_lines), held to the destination signal's range and counted. Only
// raw_ident routes reach here (parse-time + emit-time guards), so the layouts are identical.
fn gateway_forward_arms(m Model, src_bus string) []string {
	mut out := []string{}
	// NM gate: a gateway with NM enabled must stay SILENT on its MANAGED bus while asleep — a
	// forward is a TX, so it obeys the same REQ-COM-007 rule as every cyclic producer. NM runs on
	// the comm thread's own channel `ch`, opened on m.telem.bus (the `[nm].bus` field is only a
	// manifest label), so the gate applies ONLY to a forward whose DESTINATION is m.telem.bus; a
	// route to any other bus is untouched (that bus is not in this node's NM cluster).
	// Forwards are REACTIVE (they fire only on an arriving source frame) and run inside the Rx
	// drain, before this pass's g_nm.produce(); we gate on the COMMITTED state (g_nm.awake())
	// rather than restructure the drain into a post-tick forward FIFO. In a coordinated sleep the
	// sources stop, so nothing arrives to forward anyway; the gate is defense-in-depth against a
	// stray frame reaching a sleeping bus. (Cyclic producers, timer-driven, still gate post-tick.)
	for r in m.routes {
		if r.from_bus != src_bus {
			continue
		}
		nm_gate := if m.nm.on && r.to_bus == m.telem.bus { 'g_nm.awake() && ' } else { '' }
		dst := gw_var(r.to_bus, m.telem.bus)
		out << '\t\t\tif rx.id == u32(0x${r.from_id.hex()}) && rx.len == ${r.from_dlc} && rx.ext == ${r.from_ext} { // route ${r.signal}: ${r.from_bus} -> ${r.to_bus} 0x${r.to_id.hex()}'
		out << '\t\t\t\tmut ff := can.Frame{'
		out << '\t\t\t\t\tid:  u32(0x${r.to_id.hex()})'
		out << '\t\t\t\t\tlen: ${r.to_dlc}'
		out << '\t\t\t\t\text: ${r.to_ext}'
		out << '\t\t\t\t}'
		if r.signal == '' {
			// a FRAME route forwards the PDU as it is: its bytes are not this node's values
			out << '\t\t\t\tff.data = rx.data // frame route: forwarded as is, only the id/bus differ'
			out << '\t\t\t\tif ${nm_gate}${dst}.tx_ready() {'
			out << '\t\t\t\t\t${dst}.send(ff)'
			out << '\t\t\t\t\tg_fwd_count++ // count frames actually forwarded, not ones dropped on a full tx FIFO / NM sleep'
			out << '\t\t\t\t}'
		} else {
			out << route_reencode_lines(r, dst, nm_gate)
		}
		out << '\t\t\t}'
	}
	return out
}

// route_reencode_lines: a SIGNAL route on the target comm thread — the value decoded from the source
// frame and re-encoded into the destination through the one send encode (candb encode_lines:
// com.encode_raw, held to the destination signal's range, counted once sent), as the host bridge's
// route does through `_set`. The route is layout-identical (raw_ident: the frame carries only this
// signal, little-endian, at one position and scale, <= 52 bits), so the payload is copied and only the
// signal's own bits are rewritten.
fn route_reencode_lines(r Route, dst string, nm_gate string) []string {
	sg := r.dst_sg
	n := sg.length
	ind := '\t\t\t\t'
	mut out := ['${ind}ff.data = rx.data // signal route: the payload, the value re-encoded below']
	out << '${ind}mut rt_v := u64(0)'
	out << '${ind}for i in 0 .. ${n} {'
	out << '${ind}\tg := ${sg.start_bit} + i'
	out << '${ind}\trt_v |= u64((rx.data[g / 8] >> (g % 8)) & 1) << i'
	out << '${ind}}'
	raw := if sg.is_signed {
		'(if rt_v & (u64(1) << ${n - 1}) != 0 { f64(i64(rt_v) - (i64(1) << ${n})) } else { f64(rt_v) })'
	} else {
		'f64(rt_v)'
	}
	out << '${ind}rt_phys := ${raw} * ${route_f64lit(sg.factor)} + ${route_f64lit(sg.offset)}'
	out << sg.encode_lines('rt_phys', 'rt_raw', 'rt_sat', ind) or {
		panic('route: signal "${r.signal}": ${err}')
	}
	out << '${ind}for i in 0 .. ${n} {'
	out << '${ind}\tg := ${sg.start_bit} + i'
	out << '${ind}\tbm := u8(1) << (g % 8)'
	out << '${ind}\tff.data[g / 8] = (ff.data[g / 8] & ~bm) | (u8((rt_raw >> i) & 1) << (g % 8))'
	out << '${ind}}'
	out << '${ind}if ${nm_gate}${dst}.tx_ready() {'
	out << '${ind}\tif ${dst}.send(ff) && rt_sat {'
	out << '${ind}\t\ttx_sat.add(1)'
	out << '${ind}\t}'
	out << '${ind}\tg_fwd_count++ // count frames actually forwarded, not ones dropped on a full tx FIFO / NM sleep'
	out << '${ind}}'
	return out
}

fn route_f64lit(x f64) string {
	t := x.str()
	return if t.contains('.') || t.contains('e') { t } else { t + '.0' }
}

fn parse_routes(doc toml.Doc, dbc string, frames FrameCfg) []Route {
	mut routes := []Route{}
	for r in ecumodel.toml_arr(doc, 'route') {
		m := r.as_map()
		fm := (m['from'] or { toml.Any('') }).as_map()
		tm := (m['to'] or { toml.Any('') }).as_map()
		fb := (fm['bus'] or { toml.Any('') }).string()
		sig := (m['signal'] or { toml.Any('') }).string()
		// a SIGNAL route with no source bus would be silently dropped by the `continue`
		// below (a raw route with no bus is an empty section — the legacy skip); reject.
		if fb == '' {
			if sig != '' {
				panic('route: signal "${sig}" has no source bus (from = { bus = .., frame = .. })')
			}
			continue
		}
		// a signal route's id comes from to.frame; an explicit to.id (even 0) is
		// forbidden by the schema — check the KEY, not the value.
		if sig != '' {
			if _ := tm['id'] {
				panic('route: signal "${sig}" sets to.id — a signal route takes its id from to.frame (drop to.id)')
			}
		}
		routes << Route{
			from_bus:   fb
			from_frame: (fm['frame'] or { toml.Any('') }).string()
			to_bus:     (tm['bus'] or { toml.Any('') }).string()
			to_id:      schema_int(tm, 'route_to', 'id', 0, 'route to')
			signal:     sig
			to_frame:   (tm['frame'] or { toml.Any('') }).string()
		}
	}
	if routes.len > 0 {
		db := candb.load_dbc_file(dbc) or { panic('routes need a DBC: load ${dbc}: ${err}') }
		for i, r in routes {
			id := dbc_id_of(db, snake(r.from_frame)) or {
				panic('route: frame "${r.from_frame}" is not a message in ${os.file_name(dbc)}')
			}
			routes[i].from_id = id
			routes[i].from_dlc = dbc_dlc_of(db, snake(r.from_frame)) or { 8 }
			routes[i].from_ext = dbc_ext_of(db, snake(r.from_frame)) or { false }
			routes[i].to_ext = routes[i].from_ext // raw forward preserves the source width; a signal route overrides below
			if r.signal != '' {
				// SIGNAL route: resolve the DESTINATION frame's id + dlc (a distinct
				// frame from the source; NOTE: both frames must be in this ONE DBC —
				// a sysgen gateway with per-bus DBCs is P2c, the panics below fire on
				// the missing frame). Both frames' codec fns live in dbc_gen.v.
				if r.to_frame == '' {
					panic('route: signal "${r.signal}" needs a destination frame (to = { bus = .., frame = .. })')
				}
				routes[i].to_id = dbc_id_of(db, snake(r.to_frame)) or {
					panic('route: destination frame "${r.to_frame}" is not a message in ${os.file_name(dbc)} (per-bus DBCs on a gateway are P2c)')
				}
				routes[i].to_dlc = dbc_dlc_of(db, snake(r.to_frame)) or { 8 }
				routes[i].to_ext = dbc_ext_of(db, snake(r.to_frame)) or { false }
				// the routed signal must be an SG_ in BOTH frames (decode + re-encode).
				src_sg := dbc_sig_in_frame(db, snake(r.from_frame), r.signal) or {
					panic('route: signal "${r.signal}" is not in source frame "${r.from_frame}" in ${os.file_name(dbc)}')
				}
				dst_sg := dbc_sig_in_frame(db, snake(r.to_frame), r.signal) or {
					panic('route: signal "${r.signal}" is not in destination frame "${r.to_frame}" in ${os.file_name(dbc)}')
				}
				// the re-encode holds the value to the destination signal's range (REQ-COM-010)
				dst_rr := dst_sg.raw_range() or { panic('route: signal "${r.signal}" in "${r.to_frame}": ${err}') }
				if dst_rr.note != '' {
					panic('route: signal "${r.signal}" in destination frame "${r.to_frame}": ${dst_rr.note} — a sent value is held to its signal\'s range, so the range must be one a value can be sent in')
				}
				// GUARDS — a STANDALONE ecu.toml route is gated only by ecucheck, NOT
				// sysmodel's check_route_dbc, so loom2v must reject the shapes the
				// _phys/_set codec cannot faithfully translate (the dissolution rejects
				// these at syscheck; these are the same rules on the standalone path):
				// - multiplexed: the codec ignores the selector.
				if src_sg.is_multiplexed || src_sg.is_multiplexor || dst_sg.is_multiplexed
					|| dst_sg.is_multiplexor {
					panic('route: signal "${r.signal}" is multiplexed — the route codec has no multiplexor support')
				}
				// - wide integer: P2a.2b routes the PHYSICAL value through f64 (so it can
				//   transcode a differing factor/offset), which is exact only to 52 bits.
				if src_sg.length > 52 || dst_sg.length > 52 {
					panic('route: signal "${r.signal}" is >52 bits — the route carries the physical value through f64 (exact only to 52-bit integers)')
				}
				// (extended-id SOURCE and destination are now supported: Frame.ext carries
				//  the id width, the signal-route rx predicate matches rx.ext == from_ext,
				//  and the producer sends the dest frame with ext = to_ext — emb#180/#181.)
				// - big-endian (Motorola): the DLC/bounds check below assumes the
				//   little-endian [start, start+length) span; the sawtooth walk is not worth
				//   it here (the dissolution rejects Motorola routes too).
				if src_sg.byte_order != .little_endian || dst_sg.byte_order != .little_endian {
					panic('route: signal "${r.signal}" is big-endian (Motorola) — the route handles little-endian signals only')
				}
				// - the SG_ must fit its frame's payload at its actual bit POSITION, not
				//   just by width (a signal near the frame end overflows the DLC).
				if src_sg.start_bit + src_sg.length > routes[i].from_dlc * 8
					|| dst_sg.start_bit + dst_sg.length > routes[i].to_dlc * 8 {
					panic('route: signal "${r.signal}" does not fit its frame payload (source/destination DLC too small for the SG_ position)')
				}
				// remember the destination signal's bit span so validation can reject a
				// route whose value would land on the frame's E2E/SecOC protection bytes.
				routes[i].to_bit = dst_sg.start_bit
				routes[i].dst_sg = dst_sg
				routes[i].to_len = dst_sg.length
				// P2a.2b TRANSCODES the physical value (differing factor/offset/width/bit-
				// position) and RATE-ADAPTS (differing cadence) — but it routes a NUMBER, so
				// it cannot convert UNITS or ENUM meanings, and the destination must be able
				// to REPRESENT the source's range. Keep those three as guards:
				// - units must match (100 km/h routed to a mph SG_ would relabel, not convert).
				if src_sg.unit != dst_sg.unit {
					panic('route: signal "${r.signal}" unit "${src_sg.unit}" != destination "${dst_sg.unit}" — the route transcodes scale, not units')
				}
				// - VAL_ enum meanings must match at the same PHYSICAL value (the route
				//   transcodes factor/offset, so raw 100@0.1 and raw 10@1 are the SAME
				//   physical enum — compare by physical value, not raw key).
				if !val_tables_phys_equal(src_sg, dst_sg) {
					panic('route: signal "${r.signal}" source and destination VAL_ tables differ (at equal physical values) — the route does not translate enum meanings')
				}
				// - the destination must represent the source's full physical range, else the
				//   generated _set masks the converted value (e.g. 300 into an 8-bit SG_).
				slo, shi := phys_range(src_sg)
				dlo, dhi := phys_range(dst_sg)
				if slo < dlo || shi > dhi {
					panic('route: signal "${r.signal}" source range [${slo}, ${shi}] does not fit the destination range [${dlo}, ${dhi}] — the re-encode would overflow')
				}
				// A layout-IDENTICAL route — same DLC, same signal position/scale, and each
				// frame carries ONLY this signal — forwards as a raw payload copy + id remap
				// (the wire bytes are bit-identical, only the id/bus differ). The ThreadX
				// gateway comm thread emits this cheap path (no on-target decode/re-encode
				// codec); a route whose layouts differ keeps raw_ident = false and stays
				// host-only until on-target transcode lands.
				mut src_nsig := 0
				mut dst_nsig := 0
				for m2 in db.messages {
					if snake(m2.name) == snake(r.from_frame) {
						src_nsig = m2.signals.len
					}
					if snake(m2.name) == snake(r.to_frame) {
						dst_nsig = m2.signals.len
					}
				}
				routes[i].raw_ident = routes[i].from_dlc == routes[i].to_dlc
					&& src_sg.start_bit == dst_sg.start_bit && src_sg.length == dst_sg.length
					&& src_sg.factor == dst_sg.factor && src_sg.offset == dst_sg.offset
					&& src_sg.byte_order == dst_sg.byte_order && src_nsig == 1 && dst_nsig == 1
				// resolve the cadences: source bounds freshness, destination is the re-emit
				// rate (the EFFECTIVE-cadence sub-tick check is in validate_signal_routes_model,
				// which also sees an authored [[frame]].tx.cycle_ms).
				routes[i].from_cyc = dbc_cycle_of(db, snake(r.from_frame))
				routes[i].to_cyc = dbc_cycle_of(db, snake(r.to_frame))
				// an id > 0x7ff must be flagged extended: candb leaves an UNFLAGGED id > 0x7ff
				// as ext = false, and the driver would send it as an 11-bit id (truncated).
				// A correctly EFF-flagged 29-bit id is fine (from_ext/to_ext carry the width).
				if (routes[i].from_id > 0x7ff && !routes[i].from_ext)
					|| (routes[i].to_id > 0x7ff && !routes[i].to_ext) {
					panic('route: signal "${r.signal}" frame id > 0x7ff without the extended flag — a malformed DBC id')
				}
				// - the SOURCE id must be UNIQUE in the DBC: the runtime matches rx.id +
				//   rx.len + rx.ext, so a second same-id/len/width message would be mis-
				//   decoded with this frame's layout and forwarded as a fabricated value.
				//   A standard and an extended frame with the same stripped id are distinct
				//   on the wire (rx.ext disambiguates), so only a same-width clash collides.
				for m2 in db.messages {
					if snake(m2.name) != snake(r.from_frame) && m2.id == u32(routes[i].from_id)
						&& int(m2.dlc) == routes[i].from_dlc && m2.ext == routes[i].from_ext {
						panic('route: source id 0x${routes[i].from_id:x} (frame "${r.from_frame}") is shared by DBC frame "${m2.name}" at the same DLC and id width — the runtime cannot tell them apart')
					}
				}
			} else if routes[i].to_id == 0 {
				routes[i].to_id = id // raw route: keep the source id unless remapped
			}
		}
		// P2a.2b's producer composes the WHOLE destination frame from its routed
		// signals, so several routes MAY target one frame — but every SG_ in that frame
		// must be filled by a route (from THIS gateway), else a sibling ships as a stale
		// zero. Reject a route into a frame with an uncovered SG_. Also: two routes may
		// not carry the SAME signal into one frame (double-write of one field).
		mut routed_sigs := map[string][]string{} // "to_bus/to_frame" -> [signals]
		for r in routes {
			if r.signal == '' {
				continue
			}
			key := '${r.to_bus}/${r.to_frame}'
			if r.signal in routed_sigs[key] {
				panic('route: signal "${r.signal}" is routed into frame "${r.to_frame}" on "${r.to_bus}" twice — one route per destination field')
			}
			routed_sigs[key] << r.signal
		}
		for r in routes {
			if r.signal == '' {
				continue
			}
			key := '${r.to_bus}/${r.to_frame}'
			for m2 in db.messages {
				if snake(m2.name) != snake(r.to_frame) {
					continue
				}
				// a protected frame's CRC/counter (E2E) or freshness/MAC (SecOC) bytes may be
				// modeled as explicit SG_ in the DBC; the PRODUCER fills those (protect()), not
				// a route, so exempt any SG_ whose every occupied bit lies in a protection span
				// ON THIS BUS. owns() walks the signal's bits byte-order-aware (Motorola-safe).
				prot := frame_reserved_bits(frames, r.to_frame, r.to_bus)
				for sg in m2.signals {
					if sg.name in routed_sigs[key] {
						continue
					}
					mut producer_filled := true
					mut owns_any := false
					for g in 0 .. m2.dlc * 8 {
						if !sg.owns(g) {
							continue
						}
						owns_any = true
						mut in_prot := false
						for pr in prot {
							if g >= pr[0] && g < pr[1] {
								in_prot = true
								break
							}
						}
						if !in_prot {
							producer_filled = false
							break
						}
					}
					if owns_any && producer_filled {
						continue
					}
					panic('route: destination frame "${r.to_frame}" on "${r.to_bus}" has SG_ "${sg.name}" that no route fills — every signal in a routed frame must be routed (else it ships as zero)')
				}
			}
		}
	}
	return routes
}

// frame_reserved_bits returns the [lo, hi) bit ranges a frame's E2E/SecOC protection
// occupies (CRC byte + counter low nibble, or freshness byte + MAC bytes) on `bus`, from the
// resolved frame config — so an E2E layout the DBC declares counts like an authored one. Used
// to exempt producer-filled protection SG_ from the routed-signal completeness check.
fn frame_reserved_bits(f FrameCfg, frame string, bus string) [][]int {
	mut out := [][]int{}
	fk := snake(frame)
	// protection applies ONLY on the frame's bus (e2e_here/secoc_here); a route on a
	// different bus does NOT protect, so it must still fill those SG_.
	if f.e2e_here(fk, bus) {
		crc := f.e2e_crc[fk]
		ctr := f.e2e_ctr[fk]
		out << [crc * 8, crc * 8 + 8]
		out << [ctr * 8, ctr * 8 + 4] // only the LOW nibble is the counter; high nibble is free
	}
	if f.secoc_here(fk, bus) {
		fresh := f.secoc_fresh[fk]
		mac := f.secoc_mac[fk]
		out << [fresh * 8, fresh * 8 + 8]
		out << [mac * 8, mac * 8 + f.secoc_maclen[fk] * 8]
	}
	return out
}

// val_tables_phys_equal compares two DBC VAL_ enum tables by PHYSICAL value: a route
// transcodes factor/offset, so the same enum can have different raw keys on the two
// buses (raw 100@0.1 == raw 10@1 == physical 10.0). Every entry in each table must
// have a matching physical value + label in the other, so the enum meaning is
// preserved across the re-encode.
fn val_tables_phys_equal(a candb.Signal, b candb.Signal) bool {
	if a.values.len != b.values.len {
		return false
	}
	// each of a's entries must be present (same physical value + label) in b — a
	// physical compare within HALF A QUANTIZATION STEP (so fine-resolution enums with
	// distinct steps stay distinct), the raw key read as signed per the signal.
	tol := val_tol(a, b)
	for ka, va in a.values {
		pa := sig_key_phys(a, ka)
		mut found := false
		for kb, vb in b.values {
			if vb == va && f64_close(sig_key_phys(b, kb), pa, tol) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// sig_key_phys converts a DBC VAL_ raw key to its physical value. candb stores a
// negative key as its FULL u64 two's-complement (e.g. -1 -> u64(-1)), so i64(raw)
// recovers the signed value directly.
fn sig_key_phys(s candb.Signal, raw u64) f64 {
	r := if s.is_signed { f64(i64(raw)) } else { f64(raw) }
	return r * s.factor + s.offset
}

// val_tol is half the finer of the two signals' quantization steps — small enough to
// keep distinct enum states apart, large enough to absorb f64 rounding.
fn val_tol(a candb.Signal, b candb.Signal) f64 {
	mut fa := if a.factor < 0 { -a.factor } else { a.factor }
	mut fb := if b.factor < 0 { -b.factor } else { b.factor }
	step := if fa < fb && fa > 0 { fa } else { fb }
	if step <= 0 {
		return 1e-9
	}
	return step * 0.5
}

fn f64_close(x f64, y f64, tol f64) bool {
	mut d := x - y
	if d < 0 {
		d = -d
	}
	return d < tol
}

// phys_capacity returns the [min, max] PHYSICAL value a signal's WIRE ENCODING can
// hold (raw range scaled by factor/offset) — what a destination can actually carry.
fn phys_capacity(s candb.Signal) (f64, f64) {
	n := s.length
	if s.is_signed {
		half := f64(u64(1) << u64(n - 1))
		a := -half * s.factor + s.offset
		b := (half - 1) * s.factor + s.offset
		return if a < b { a, b } else { b, a }
	}
	rmax := f64((u64(1) << u64(n)) - 1)
	a := s.offset
	b := rmax * s.factor + s.offset
	return if a < b { a, b } else { b, a }
}

// phys_range returns the CONTRACT range a route treats a signal as carrying: the
// authored DBC [min|max] INTERSECTED with the wire capacity (an authored range wider
// than the encoding can hold is clamped to what the wire can carry), else the capacity.
fn phys_range(s candb.Signal) (f64, f64) {
	clo, chi := phys_capacity(s)
	if s.maximum > s.minimum {
		lo := if s.minimum > clo { s.minimum } else { clo }
		hi := if s.maximum < chi { s.maximum } else { chi }
		return lo, hi
	}
	return clo, chi
}

// dbc_cycle_of returns the GenMsgCycleTime (ms) of the message whose snake-name is
// `key`, or 0 if unknown — the source cadence bounds route freshness, the
// destination cadence is the re-emit rate.
fn dbc_cycle_of(db candb.Database, key string) int {
	for m in db.messages {
		if snake(m.name) == key {
			return m.cycle_ms
		}
	}
	return 0
}

// dbc_sig_in_frame returns the SG_ named `signame` in the message whose snake-name
// is `frame_key`, or none. Used to check a routed signal's layout in a SPECIFIC
// frame (a signal route decodes from one frame and re-encodes into another).
fn dbc_sig_in_frame(db candb.Database, frame_key string, signame string) ?candb.Signal {
	for m in db.messages {
		if snake(m.name) != frame_key {
			continue
		}
		for s in m.signals {
			if s.name == signame {
				return s
			}
		}
	}
	return none
}

// parse_isotp parses the [isotp] connection — the node's one diagnostic server on CAN (one server
// per node, docs/diagnostics.md, so a table and not an array: the old [[isotp]] form, and server
// keys left in it, are refused by ecumodel.validate with the move they need).
fn parse_isotp(doc toml.Doc) []IsotpConn {
	iv := doc.value_opt('isotp') or { return []IsotpConn{} }
	if iv !is map[string]toml.Any {
		return []IsotpConn{}
	}
	m := iv.as_map()
	c := IsotpConn{
		name:          'diag'
		bus:           (m['bus'] or { toml.Any('') }).string()
		rx_id:         toml_int(m, 'rx_id', 0, 0, 0x1FFFFFFF, '[isotp]')
		tx_id:         toml_int(m, 'tx_id', 0, 0, 0x1FFFFFFF, '[isotp]')
		bs:            int((m['bs'] or { toml.Any(0) }).int())
		stmin:         int((m['stmin_ms'] or { toml.Any(0) }).int())
		functional_id: toml_int(m, 'functional_id', 0, 0, 0x1FFFFFFF, '[isotp]')
	}
	// the connection matches and sends its ids as standard frames: a wider value never matches
	// on receive and goes out masked on transmit
	for field, v in {
		'rx_id': c.rx_id
		'tx_id': c.tx_id
	} {
		if !schema_key('isotp', field).in_range(v) {
			panic('loom2v: [isotp] ${field} 0x${v.hex()} must be a standard 11-bit id (<= 0x${schema_key('isotp', field).max:X})')
		}
	}
	if c.functional_id != 0 {
		// the bridge matches it as a standard frame, and it must not be the physical id
		fk := schema_key('isotp', 'functional_id')
		if !fk.in_range(c.functional_id) {
			panic('loom2v: [isotp] functional_id 0x${c.functional_id.hex()} must be a standard 11-bit id (<= 0x${fk.max:X})')
		}
		if c.functional_id == c.rx_id || c.functional_id == c.tx_id {
			panic('loom2v: [isotp] functional_id 0x${c.functional_id.hex()} is also the connection\'s physical rx/tx id')
		}
	}
	return [c]
}

// parse_dids parses [[did]] UDS Data Identifiers: constant (ascii/bytes), writable RAM, or live signal.
fn parse_dids(doc toml.Doc) []DidCfg {
	mut dids := []DidCfg{}
	for d in ecumodel.toml_arr(doc, 'did') {
		m := d.as_map()
		// 1..0xFFFF, refused here — the one place every DID consumer reads it from — before the
		// server's u16 narrows it
		id := schema_int(m, 'did', 'id', 0, '[[did]] (a 16-bit data identifier)')
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
		// the server's tables are fixed arrays: an oversized config would index past them
		if bytes.len > uds.max_did_data {
			panic('loom2v: [[did]] 0x${id.hex()} holds ${bytes.len} bytes — a DID stores at most ${uds.max_did_data} (comm/uds max_did_data)')
		}
		pname := (m['param'] or { toml.Any('') }).string()
		pstatus := (m['param_status'] or { toml.Any(false) }).bool()
		if pname != '' || pstatus {
			what := if pname != '' { 'codes parameter "${pname}"' } else { 'is the parameter status' }
			for k in ['ascii', 'bytes', 'signal', 'writable'] {
				if k in m {
					panic('loom2v: [[did]] 0x${id.hex()} ${what} — its record is the parameter\'s, so `${k}` has no place there')
				}
			}
			if pname != '' && pstatus {
				panic('loom2v: [[did]] 0x${id.hex()} is both a parameter and the parameter status')
			}
			if pstatus && 'write' in m {
				panic('loom2v: [[did]] 0x${id.hex()} is the parameter status, which a tester reads and never writes — drop `write`')
			}
		}
		tx_sat := (m['tx_saturations'] or { toml.Any(false) }).bool()
		if tx_sat {
			for k in ['ascii', 'bytes', 'signal', 'writable', 'param', 'param_status', 'write'] {
				if k in m {
					panic('loom2v: [[did]] 0x${id.hex()} is the count of saturated sent values, which the node keeps and a tester only reads — `${k}` has no place there')
				}
			}
			bytes = [u8(0), 0, 0, 0] // the record's shape; the encoding context writes the count
		}
		rd_s, rd_sec := parse_did_access(m, 'read', id)
		wr_s, wr_sec := parse_did_access(m, 'write', id)
		if 'write' in m && 'writable' in m && !(m['writable'] or { toml.Any(false) }).bool() {
			panic('loom2v: [[did]] 0x${id.hex()} has writable = false AND a write = {...} gate — say which')
		}
		// a `write = {...}` gate implies the DID is writable, and so does coding a parameter
		writable := (m['writable'] or { toml.Any(false) }).bool() || 'write' in m || pname != ''
		// a RAM cell's declared size is its record: 0x2E accepts exactly that many bytes (comm/uds,
		// 0x13 otherwise), so a writable cell with none could never be written. A parameter's size
		// is its width (comm/param bind); a live DID is refused as writable by validate_live_dids.
		if writable && pname == '' && 'signal' !in m && bytes.len == 0 {
			panic('loom2v: [[did]] 0x${id.hex()} is writable but declares no record — give it `bytes` or `ascii`: 0x2E accepts a record of exactly that size')
		}
		dids << DidCfg{
			id:             id
			bytes:          bytes
			writable:       writable
			signal:         (m['signal'] or { toml.Any('') }).string()
			param:          pname
			param_status:   pstatus
			tx_saturations: tx_sat
			read_sessions:  rd_s
			write_sessions: wr_s
			read_security:  rd_sec
			write_security: wr_sec
		}
	}
	// one id, one row: the server serves the FIRST row of an id, so a repeat would carry gates and
	// bindings nobody is served by — a weaker-gated twin of a parameter DID would code it
	for i, d in dids {
		for e in dids[..i] {
			if e.id == d.id {
				panic('loom2v: [[did]] 0x${d.id.hex()} is declared twice — one DID, one row (the server answers the first)')
			}
		}
	}
	if dids.filter(it.tx_saturations).len > 1 {
		panic('loom2v: ${dids.filter(it.tx_saturations).len} [[did]]s are the count of saturated sent values — one says it')
	}
	if dids.len > uds.max_dids {
		panic('loom2v: ${dids.len} [[did]]s — a diagnostic server holds at most ${uds.max_dids} (comm/uds max_dids)')
	}
	return dids
}

// parse_did_access reads a [[did]] `read = { session = [...], security = N }` (or `write`) gate
// into the server's session mask (uds.in_*) and security level. Absent = every session, no
// security.
fn parse_did_access(m map[string]toml.Any, key string, id int) (u8, u8) {
	acc := m[key] or { return u8(0), u8(0) }
	am := acc.as_map()
	mut mask := u8(0)
	for sv in (am['session'] or { toml.Any([]toml.Any{}) }).array() {
		mask |= session_bit(sv.string()) or {
			panic('loom2v: [[did]] 0x${id.hex()} ${key}.session ${err}')
		}
	}
	if 'session' in am && mask == 0 {
		panic('loom2v: [[did]] 0x${id.hex()} ${key}.session is empty — omit it for "every session"')
	}
	sec := (am['security'] or { toml.Any(0) }).int()
	if !schema_key('did_access', 'security').in_range(sec) {
		panic('loom2v: [[did]] 0x${id.hex()} ${key}.security ${sec} is not a 0x27 level the server serves (1..${schema_key('did_access',
			'security').max})')
	}
	// 0x27 unlocks in extended (programming too, but an application server refuses that session
	// until the bootloader handoff, R2), and every session change relocks: a gate whose sessions
	// leave out extended could never be opened
	if sec != 0 && mask != 0 && mask & uds.in_extended == 0 {
		panic('loom2v: [[did]] 0x${id.hex()} ${key} needs security ${sec} but is not allowed in the extended session, the only one an application server unlocks in — it could never be opened')
	}
	return mask, u8(sec)
}

// session_bit: a session's name as the server's session-mask bit (uds.in_*) — the one spelling of
// the names a [[did]] gate and a [uds] service row share.
fn session_bit(name string) !u8 {
	return match name {
		'default' { uds.in_default }
		'programming' { uds.in_programming }
		'extended' { uds.in_extended }
		'safety' { uds.in_safety }
		else { error('"${name}" is not a session (${cfgschema.session_names().join(' / ')})') }
	}
}

fn parse_buses(doc toml.Doc) (map[string]bool, map[string]int, map[string]string) {
	mut buses := map[string]bool{}
	mut bus_core := map[string]int{}
	mut bus_kind := map[string]string{} // 'can' (default) | 'eth' (docs/someip.md)
	// value_opt (not value): no [bus] must yield no buses — value() returns Null
	// for a missing key, which as_map() coerces into a phantom "0" entry.
	if bv := doc.value_opt('bus') {
		for bname, bcfg in bv.as_map() {
			buses[bname] = true
			bus_core[bname] = int((bcfg.as_map()['core'] or { toml.Any(0) }).int())
			bus_kind[bname] = (bcfg.as_map()['kind'] or { toml.Any('can') }).string()
		}
	}
	return buses, bus_core, bus_kind
}

// --- SOME/IP over eth (docs/someip.md): the [someip] identity + eth [[frame]]s
//     with their DERIVED payload layout (signals in list order, fields
//     name-sorted, LE, natural widths). ecumodel.validate_someip has already
//     gated ranges/directions/bounds before this parse runs. ---

// EthField is one derived-layout cell: signal + field at a byte offset.
struct EthField {
	sig    string // signal name (config spelling)
	field  string // field name
	offset int
	width  int
	typ    string // the V type ('bool','u8',...,'f64')
}

// peer_parts splits the (ecucheck-validated) IPv4 address:port peer into its
// four octets + port, for emission as fixed-width scalar consts.
fn peer_parts(peer string) ([]int, int) {
	mut colon := -1
	for i, c in peer {
		if c == `:` {
			colon = i
		}
	}
	if colon < 0 {
		return [0, 0, 0, 0], 0
	}
	mut oct := []int{}
	for o in peer[..colon].split('.') {
		oct << o.int()
	}
	for oct.len < 4 {
		oct << 0
	}
	return oct, peer[colon + 1..].int()
}

fn parse_partitions(doc toml.Doc) PartMap {
	mut p := PartMap{}
	for pt in ecumodel.toml_arr(doc, 'partition') {
		m := pt.as_map()
		pname := (m['name'] or { toml.Any('') }).string()
		p.core_of[pname] = int((m['core'] or { toml.Any(0) }).int())
		img := (m['image'] or { toml.Any('') }).string()
		if img != '' {
			p.image[pname] = img
		}
		p.external[pname] = (m['external'] or { toml.Any(false) }).bool() || img != ''
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

// dbc_msg_named is the DBC message whose snake-cased name is `fk`.
fn dbc_msg_named(db candb.Database, fk string) ?candb.Message {
	for m in db.messages {
		if snake(m.name) == fk {
			return m
		}
	}
	return none
}

// set_e2e records a frame's resolved E2E layout (ecumodel.resolve_frame_e2e), refusing a Data ID
// the protect/verify calls would narrow: they take a u16, so a wider one would alias.
fn (mut f FrameCfg) set_e2e(fk string, e ecumodel.FrameE2e) {
	if e.data_id < 0 || e.data_id > 0xffff {
		panic('frame "${fk}": e2e data_id 0x${e.data_id.hex()} is out of range (0..0xFFFF)')
	}
	f.e2e_on[fk] = true
	f.e2e_id[fk] = e.data_id
	f.e2e_crc[fk] = e.crc_pos
	f.e2e_ctr[fk] = e.counter_pos
	if e.bad_timeout != '' {
		f.e2e_timeout_bad[fk] = e.bad_timeout
	} else {
		f.e2e_timeout_us[fk] = ms_to_us(e.timeout_ms, 'frame "${fk}": E2E timeout')
	}
}

fn parse_frames(doc toml.Doc, eth string, buses map[string]bool, bus_kind map[string]string, db candb.Database, carries_signals map[string]bool) FrameCfg {
	mut f := FrameCfg{}
	mut seen_frames := map[string]string{} // snake(name) -> the bus it was authored on
	for fr in ecumodel.toml_arr(doc, 'frame') {
		fm := fr.as_map()
		// eth frames live in m.eth_frames (parse_eth_frames), NOT in the CAN
		// FrameCfg maps: these are keyed by snake(name) only, so an eth frame
		// sharing a CAN message's name would overwrite the CAN E2E settings
		if eth != '' && (fm['bus'] or { toml.Any('') }).string() == eth {
			continue
		}
		fk := snake((fm['name'] or { toml.Any('') }).string())
		fbus := (fm['bus'] or { toml.Any('') }).string()
		// a [[frame]].bus must be a DECLARED [bus.*]: protection is applied only when the
		// frame's bus equals the route/producer bus (e2e_here/secoc_here), so a misspelled
		// bus would silently disable protection and put an unprotected PDU on the wire.
		if fbus !in buses {
			panic('frame "${fk}": bus "${fbus}" is not a declared [bus.*] — protection would be silently disabled')
		}
		// FrameCfg (tx mode / rx deadline / E2E / SecOC) is keyed by frame NAME only,
		// so a second [[frame]] with the same name — e.g. the same DBC frame on another
		// bus — would silently overwrite the first's config, and a route would stamp the
		// wrong bus's protection onto a frame. Enforce name uniqueness so name == identity
		// (true per-(bus,frame) keying arrives with per-bus DBCs on a gateway, P2c).
		if prev := seen_frames[fk] {
			panic('frame: "${fk}" is declared twice ([[frame]] on "${prev}" and "${fbus}") — frame names must be unique (per-bus DBCs on a gateway are P2c)')
		}
		seen_frames[fk] = fbus
		f.frame_bus[fk] = fbus
		if 'tx' in fm {
			txm := (fm['tx'] or { toml.Any('') }).as_map()
			f.tx_mode[fk] = (txm['mode'] or { toml.Any('cyclic') }).string()
			f.tx_cycle_us[fk] = int((txm['cycle_ms'] or { toml.Any(0) }).int()) * 1000
			f.tx_min_us[fk] = int((txm['min_delay_ms'] or { toml.Any(0) }).int()) * 1000
		}
		if 'rx' in fm {
			rxm := (fm['rx'] or { toml.Any('') }).as_map()
			f.rx_timeout_us[fk] = ms_to_us((rxm['timeout_ms'] or { toml.Any(0) }).i64(), 'frame "${fk}": rx.timeout_ms')
		}
		// E2E: the [[frame]].e2e table, else the DBC's declaration (blobly_net#271)
		has_e2e := 'e2e' in fm
		em := if has_e2e { (fm['e2e'] or { toml.Any('') }).as_map() } else { map[string]toml.Any{} }
		e, on := ecumodel.resolve_frame_e2e(fk, has_e2e, em, dbc_msg_named(db, fk)) or {
			panic(err.msg())
		}
		if on {
			f.set_e2e(fk, e)
		}
		if 'timeout_ms' in em {
			f.e2e_timeout_authored[fk] = true
		}
		if 'secoc' in fm {
			sm := (fm['secoc'] or { toml.Any('') }).as_map()
			f.secoc_on[fk] = true
			f.secoc_id[fk] = schema_int(sm, 'secoc', 'data_id', 0, 'frame "${fk}" secoc')
			f.secoc_fresh[fk] = int((sm['fresh_pos'] or { toml.Any(0) }).int())
			f.secoc_mac[fk] = int((sm['mac_pos'] or { toml.Any(0) }).int())
			f.secoc_maclen[fk] = int((sm['mac_len'] or { toml.Any(4) }).int())
			f.secoc_key[fk] = parse_hex((sm['key'] or { toml.Any('') }).string())
		}
		// E2E + SecOC on ONE frame COMPOSE since REQ-E2E-004 landed: the E2E CRC
		// excludes the SecOC freshness/MAC windows (protect_ex/check_ex), TX runs
		// E2E-then-SecOC, RX verifies SecOC-then-E2E nested. The field-disjointness
		// this depends on is validated in build_model's protected-frames walk (the
		// 'REQ-E2E-004 requires disjoint protection bytes' panic).
	}
	// a frame only the DBC protects has no [[frame]] to say its bus: the ECU's one CAN bus. Only
	// messages carrying this ECU's own signals — a shared DBC declares other nodes' frames too,
	// and a routed frame on a gateway names its bus with a [[frame]]
	can := buses.keys().filter(bus_kind[it] or { 'can' } == 'can')
	for m in db.messages {
		fk := snake(m.name)
		if fk in seen_frames || fk !in carries_signals {
			continue
		}
		e, on := ecumodel.dbc_e2e(m) or { panic(err.msg()) }
		if !on {
			continue
		}
		if can.len != 1 {
			panic('frame "${fk}": the DBC declares E2E for it, but this ECU has ${can.len} CAN buses — ' +
				'add a [[frame]] naming its bus')
		}
		f.frame_bus[fk] = can[0]
		f.set_e2e(fk, e)
	}
	return f
}

fn parse_telemetry(doc toml.Doc) TelemetryCfg {
	mut t := TelemetryCfg{}
	if tcfg := doc.value_opt('telemetry') {
		tm := tcfg.as_map()
		t.on = (tm['enabled'] or { toml.Any(false) }).bool()
		t.bus = (tm['bus'] or { toml.Any('') }).string()
		t.id = u32(toml_int(tm, 'id', 0, 0, 0x1FFFFFFF, '[telemetry]'))
		t.detail_id = u32(toml_int(tm, 'detail_id', 0, 0, 0x1FFFFFFF, '[telemetry]'))
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
mut:
	buses        map[string]bool
	bus_core     map[string]int
	bus_kind     map[string]string // 'can' (default) | 'eth'
	eth          string            // the (single) eth bus name, '' = none
	eth_iface    string            // its [bus.<eth>].interface: the node's static address
	eth_netmask  ?string           // ...and its subnet (none = tools/netcfg's defaults)
	eth_gateway  ?string
	// a subnet key on a CAN bus ("<bus>] `netmask`"), which validate_net refuses
	non_eth_net_keys []string
	someip       SomeipCfg
	eth_frames   []EthFrame
	sig_of       map[string]SigInfo
	sig_names    []string
	has_external bool // any bus-endpoint signal (CAN or eth)
	has_can_ext  bool // any CAN bus-endpoint signal (drives driver.can/DBC paths)
	frames       FrameCfg
	routes       []Route
	isotp_conns  []IsotpConn // [isotp]: none, or the one connection
	uds          UdsCfg      // [uds]: the ISO 14229 server those transports carry (gen_diag.v)
	boot         BootCfg     // [boot]: the node runs behind the bootloader; 0x10 02 hands over to it (gen_diag.v)
	doip         DoipCfg // [doip]: the diagnostic server over DoIP too (gen_doip.v)
	dids         []DidCfg
	params       []ParamCfg // [[param]] in declaration order (gen_param.v)
	faults       []FaultCfg // [[fault]] in declaration order = the fault memory's slot order
	fault_cycle  string     // [fault_memory] cycle = "Signal.field" (bool) or "power" — the operation cycle ('' = NM's, D3)
	fault_entries int       // [fault_memory] entries: the snapshot entries (default: one per fault with `freeze`, at most fault.max_entries)
	part         PartMap
	telem        TelemetryCfg
	target       TargetCfg
	io_points    []IoPoint // [[io.gpio]] points in driver-channel order (docs/io.md)
	io_core      int       // the io thread's home core ([io].core, default 0)
	trace        TraceCfg
	shell        ShellCfg
	nm           NmCfg
	display      DisplayCfg
	// Cross-core signal slots (derived, never configured): every REMOTE signal — one whose
	// `from` partition lives in another image — gets an xioc slot, allocated in declaration
	// order. Slot numbers surface ONLY in gen/xcore_gen.h (the contract header both images
	// compile against). xcore_names keeps the allocation order for stable emission.
	xcore_idx   map[string]int
	xcore_names []string
	// WIDE remote signals (si.wide): byte offset of each signal's xioc_n channel inside the
	// board's wide window (xcore.h XCORE_XW_ADDR), 32-aligned, allocation in declaration order;
	// xcore_xw_total is the window budget consumed (checked against XCORE_XW_MAX in xcore_gen.h).
	xcore_xw_off   map[string]int
	xcore_xw_total int
	// [nvm] (gen_nvm.v): persistent-signal names in declaration order + their
	// schema-identity block ids — all derived, never configured beyond intent.
	nvm       NvmCfg
	nvm_names []string
	nvm_ids   map[string]u16
	// the persisted fault memory's journal blocks (derive_fault_nvm): its status image, and each
	// fault's snapshot (0 = the fault has no `freeze`)
	fault_status_id u16
	fault_snap_ids  []u16
	fault_snap_ids_b []u16 // each fault's second snapshot block (persist.v A / B)
	fault_grace_us  u64 // the cycle-end barrier: twice the longest period of a fault-testing handler
	bulk      []BulkPoolCfg
	fb_reads    map[string]int      // signal -> how many FB handlers read it
	fb_reads_by map[string][]string // fb -> the signals its handlers read
}

fn build_model(doc toml.Doc, dbc string) Model {
	if _ := doc.value_opt('duo') {
		panic('loom2v: [duo] has dissolved into the signal model — declare cross-core signals as ' +
			'[[signal]] from = "<satellite partition>" (slots are derived; see docs/multi-image.md)')
	}
	buses, bus_core, bus_kind := parse_buses(doc)
	// at most ONE eth bus per image (ecucheck-enforced); '' = none
	mut eth := ''
	for bname, k in bus_kind {
		if k == 'eth' {
			eth = bname
		}
	}
	mut sig_of, sig_names, has_external, has_can_ext := parse_signals(doc, dbc, buses, eth)
	// the frames' E2E is the [[frame]] table's, else the DBC's (blobly_net#271). A DBC file
	// that will not parse is refused as the other loaders refuse it; none declares nothing.
	db := candb.load_dbc_file(dbc) or {
		if os.is_file(dbc) {
			panic('loom2v: ${dbc}: ${err}')
		}
		candb.Database{}
	}
	mut carries_signals := map[string]bool{} // DBC messages this ECU's own bus signals ride in
	for _, si in sig_of {
		if si.external && si.dbc_msg != '' {
			carries_signals[si.dbc_msg] = true
		}
	}
	frames := parse_frames(doc, eth, buses, bus_kind, db, carries_signals)
	part := parse_partitions(doc)
	io_points, io_core := parse_io(doc, sig_of)
	// P1 generates the SAME-core transport derivation only (triple): the io thread
	// and every io-signal endpoint must share [io].core (docs/io.md).
	for pt in io_points {
		si := sig_of[pt.name] or { continue }
		other := if pt.output { si.from } else { si.to }
		pname := if other in part.core_of { other } else { part.thread_part[other] or { '' } }
		if (part.core_of[pname] or { 0 }) != io_core {
			panic('loom2v: io signal "${pt.name}": cross-core io arrives with the target phase ' +
				'(endpoint "${other}" is on core ${part.core_of[pname] or { 0 }}, [io].core is ${io_core})')
		}
	}
	// Derive the cross-image crossings: a signal FROM a partition whose code lives in another
	// image is REMOTE — it rides an xioc slot (see docs/multi-image.md; the transport is derived
	// from the topology, never configured). The satellite side publishes, this image polls.
	mut xcore_idx := map[string]int{}
	mut xcore_names := []string{}
	mut xcore_xw_off := map[string]int{}
	mut xcore_xw_total := 0
	mut xcore_pair_n := 0
	for sname in sig_names {
		mut si := sig_of[sname] or { continue }
		from_ext := part.external[si.from] or { false }
		to_ext := part.external[si.to] or { false }
		if to_ext {
			panic('loom2v: signal "${sname}" flows INTO satellite partition "${si.to}" — a ' +
				'satellite-side consumer is not generated yet; satellites only publish (from = "${si.to}")')
		}
		if !from_ext {
			continue
		}
		si.remote = true
		// One u32 LANE per field (docs/multi-image.md "Wide remote signals", REQ-INV-006:
		// capacity is placement-independent). A 1-2 x u32 signal without `valid` keeps the
		// bench-verified {a,b} pair cell byte-identically; anything else rides a wide
		// xioc_n channel (words = field count, <= one PDU). 64-bit fields stay rejected
		// until a signal earns them; past one PDU it is not a signal on ANY transport —
		// that is the bulk ring's job.
		if si.fields.len < 1 || si.fields.len > 16 {
			panic('loom2v: remote signal "${sname}" has ${si.fields.len} fields — lanes carry ' +
				'1..16 u32 lanes (one PDU, 64 B); a bigger payload is bulk, not a signal ' +
				'(docs/bulk-transport.md)')
		}
		for f in si.fields {
			if f.typ !in ['u32', 'u16', 'u8', 'bool'] {
				panic('loom2v: remote signal "${sname}" field "${f.name}" is ${f.typ} — a lane ' +
					'carries a <=32-bit field (u32/u16/u8/bool)')
			}
		}
		si.wide = si.fields.len > 2 || si.fields.any(it.typ != 'u32')
		if si.wide {
			// xioc_n geometry: 32 B header + XIOC_SLOTS(4) x (1 seq + lanes) u32s, rounded up
			// to the 32 B line so neighbouring channels never share one.
			xcore_xw_off[sname] = xcore_xw_total
			ch_bytes := 32 + 4 * 4 * (1 + si.fields.len)
			xcore_xw_total += (ch_bytes + 31) & ~31
		} else {
			xcore_idx[sname] = xcore_pair_n
			xcore_pair_n++
		}
		xcore_names << sname
		sig_of[sname] = si
	}
	// ONE satellite producer per model, counting BOTH generated (image =) and
	// hand-written (external = true) satellites: every producer publishes the layout-id
	// acknowledgement into the single XCORE_LAYOUT_ADDR cell, so a second satellite of
	// either kind would race it — a current one's id winning would open polling for a
	// stale sibling's incompatible slots (codex #211 r8/r10). The per-satellite-cell
	// design (cells at XCORE_LAYOUT_ADDR + 4*i, each signal gated on its producer's cell)
	// lands with the first real multi-satellite target.
	mut xcore_producers := []string{}
	for sname in xcore_names {
		si := sig_of[sname] or { continue }
		if si.from !in xcore_producers {
			xcore_producers << si.from
		}
	}
	// SPSC per remote channel, validated HERE (not only in the comm-thread walk, which a
	// slot-only model without a comm thread never enters — codex #211 r11). The unit is
	// the PRODUCER CONTEXT — the thread — not the handler: two handlers on one Loom
	// thread run serially and are one valid producer (codex #211 r14, the same rule
	// ecumodel's writer_threads uses).
	mut remote_writer_ctx := map[string][]string{} // signal -> distinct writing threads
	for fb in ecumodel.toml_arr(doc, 'fb') {
		fbm := fb.as_map()
		fbname := (fbm['name'] or { toml.Any('') }).string()
		thr := part.fb_thread[fbname] or { fbname } // unassigned fb: itself as context
		for h in (fbm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			for w in (h.as_map()['writes'] or { toml.Any([]toml.Any{}) }).array() {
				wn := w.string()
				if thr !in (remote_writer_ctx[wn] or { []string{} }) {
					remote_writer_ctx[wn] << thr
				}
			}
		}
	}
	for sname in xcore_names {
		mut ctxs := remote_writer_ctx[sname] or { []string{} }
		if ctxs.len > 1 {
			ctxs.sort()
			panic('loom2v: remote signal "${sname}" is written from ${ctxs.len} threads ' +
				'(${ctxs.join(', ')}) — an xioc channel has exactly ONE producer context ' +
				'(SPSC); keep its writers on one thread or split the signal')
		}
	}
	// Symmetric SINGLE-CONSUMER guard (codex #238): the owner-FB read path emits C.xcore_poll,
	// whose reader state (seq/a/b) is ONE static per slot in the node's target_ext.c. Two owner threads polling
	// the same slot share that state — a preemption mid-update can tear or regress the last-good
	// value. Count owner-side reader THREADS (external/image partitions read via their own image,
	// not xcore_poll); >1 is the rung-2c (FB-held reader state) boundary, rejected until it lands.
	mut remote_reader_ctx := map[string][]string{} // signal -> distinct owner reader threads
	for fb in ecumodel.toml_arr(doc, 'fb') {
		fbm := fb.as_map()
		fbname := (fbm['name'] or { toml.Any('') }).string()
		thr := part.fb_thread[fbname] or { fbname }
		if part.external[part.thread_part[thr] or { '' }] {
			continue // satellite/external reader: not an xcore_poll caller in this image
		}
		for h in (fbm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			for r in (h.as_map()['reads'] or { toml.Any([]toml.Any{}) }).array() {
				rn := r.string()
				if rn in xcore_idx && thr !in (remote_reader_ctx[rn] or { []string{} }) {
					remote_reader_ctx[rn] << thr
				}
			}
		}
	}
	for sname in xcore_names {
		mut ctxs := remote_reader_ctx[sname] or { []string{} }
		if ctxs.len > 1 {
			ctxs.sort()
			panic('loom: cross-core signal "${sname}" is read by ${ctxs.len} owner threads ' +
				'(${ctxs.join(', ')}) — xcore_poll holds ONE shared reader state per slot, so ' +
				'multiple owner readers would tear the last-good value; keep its readers on one ' +
				'thread, or wait for FB-held reader state (rung 2c)')
		}
	}
	if xcore_producers.len > 1 {
		xcore_producers.sort()
		panic('loom2v: ${xcore_producers.len} satellite partitions produce remote signals ' +
			'(${xcore_producers.join(', ')}) — the cross-core layout handshake carries ONE ' +
			'satellite today (generated or hand-written); see the per-cell design note here')
	}
	m := Model{
		buses:        buses
		bus_core:     bus_core
		sig_of:       sig_of
		sig_names:    sig_names
		has_external: has_external
		has_can_ext:  has_can_ext
		bus_kind:     bus_kind
		eth:          eth
		eth_iface:    bus_interface(doc, eth)
		eth_netmask:  bus_opt(doc, eth, 'netmask')
		eth_gateway:  bus_opt(doc, eth, 'gateway')
		non_eth_net_keys: non_eth_net_keys(doc, bus_kind)
		someip:       parse_someip(doc)
		eth_frames:   parse_eth_frames(doc, eth, sig_of)
		frames:       frames
		routes:       validate_route_cores(parse_routes(doc, dbc, frames), bus_core, bus_kind)
		isotp_conns:  parse_isotp(doc)
		uds:          parse_uds(doc)
		boot:         parse_boot(doc)
		doip:         parse_doip(doc)
		dids:         parse_dids(doc)
		params:       parse_params(doc)
		faults:       parse_faults(doc)
		fault_cycle:  parse_fault_cycle(doc)
		fault_entries: parse_fault_entries(doc)
		part:         part
		telem:        parse_telemetry(doc)
		target:       parse_target(doc)
		io_points:    io_points
		io_core:      io_core
		trace:        parse_trace(doc, dbc)
		shell:        parse_shell(doc, dbc)
		nm:           parse_nm(doc, dbc)
		display:      parse_display(doc)
		xcore_idx:      xcore_idx
		xcore_names:    xcore_names
		xcore_xw_off:   xcore_xw_off
		xcore_xw_total: xcore_xw_total
		nvm:          parse_nvm(doc)
		bulk:         parse_bulk(doc)
		fb_reads:     fb_read_counts(doc)
		fb_reads_by:  fb_reads_of(doc)
	}
	validate_signal_routes_model(m, doc)
	validate_uds(m)
	validate_live_dids(m)
	validate_faults(m, doc)
	validate_e2e_timeouts(m)
	for sname in m.sig_names {
		si := m.sig_of[sname] or { continue }
		// the lost counter is what the E2E sequence check counts: without E2E on the frame it
		// would read 0 forever — a counter that can never move is a config error, not a zero
		if si.lost_type != '' && si.bus != m.eth && !m.frames.e2e_here(si.dbc_msg, si.bus) {
			panic('loom2v: signal "${sname}" has a `lost` counter, but its frame "${si.dbc_msg}" carries no E2E on ${si.bus} — only the E2E sequence check can count lost frames')
		}
	}
	return m
}

// validate_signal_routes_model checks a SIGNAL route against the rest of the model
// (things parse_routes can't see with the DBC alone): the destination bus's fd
// capacity, that the routed frames carry no E2E/SecOC the forwarder can't
// verify/re-protect, and that no OTHER writer (a tx signal/frame, or another route)
// already owns the destination frame. The dissolution enforces these at syscheck;
// a STANDALONE ecu.toml route reaches only this gate.
fn validate_signal_routes_model(m Model, doc toml.Doc) {
	mut bus_fd := map[string]bool{}
	if bv := doc.value_opt('bus') {
		for bname, bc in bv.as_map() {
			bus_fd[bname] = (bc.as_map()['fd'] or { toml.Any(false) }).bool()
		}
	}
	for r in m.routes {
		// both ends of every route — a signal route's two frames, or the one frame a raw route
		// forwards unchanged — fit their buses (frame_len_refusal, the one rule)
		to_dlc := if r.signal == '' { r.from_dlc } else { r.to_dlc }
		if why := frame_len_refusal(r.from_dlc, bus_fd[r.from_bus] or { false }) {
			panic('route: source frame "${r.from_frame}" on bus "${r.from_bus}" is ${why}')
		}
		if why := frame_len_refusal(to_dlc, bus_fd[r.to_bus] or { false }) {
			panic('route: frame ${if r.signal == '' { r.from_frame } else { r.to_frame }} forwarded onto bus "${r.to_bus}" is ${why}')
		}
		if r.signal == '' {
			continue
		}
		// On the ThreadX target the comm thread forwards LAYOUT-IDENTICAL routes directly
		// (raw payload copy + id remap — see raw_ident in parse_routes). A route whose
		// source and destination layouts DIFFER would need an on-target decode/re-encode
		// codec the comm thread does not emit yet, so it stays host-only: fail fast with a
		// route-specific message.
		if m.target.threadx && !r.raw_ident {
			panic('route: signal "${r.signal}" is on a [target] kind="threadx" node but its ' +
				'source and destination frame layouts differ — the ThreadX comm thread forwards ' +
				'layout-identical routes only (raw copy + id remap); on-target transcode is a ' +
				'follow-up, so route this signal on the host target for now')
		}
		// The ThreadX gateway opens each route bus with its OWN fd flag (the comm thread's
		// ch/ch_<bus>.open(idx, bus_fd)), so a classic<->FD forward is a raw copy + id remap
		// where the destination channel re-frames: a classic 8-byte payload forwarded onto an
		// FD bus goes out FD, and an FD frame onto a classic bus goes out classic. Layouts are
		// still required identical (checked above); the length rule below rejects a >8-byte
		// route onto a classic destination. #266.
		frof := snake(r.from_frame)
		tof := snake(r.to_frame)
		if m.target.threadx {
			// The comm thread opens each route bus by its single FDCAN index. Reject a route bus
			// whose interface isn't exactly can0/can1: a name like "edge" or "can9" would silently
			// map to the wrong (fdcan_index_of defaults to 0) or a nonexistent instance. idx 2
			// (FDCAN3) is wired on the 3-FDCAN parts (boards/common/vectors_h72x.S, #360) but not
			// on the H74x/H75x, and this generator does not know the part, so it stays refused.
			for b in [r.from_bus, r.to_bus] {
				mut digits := ''
				for c in b {
					if c >= `0` && c <= `9` {
						digits += c.ascii_str()
					}
				}
				if digits.len != 1 || digits[0] < `0` || digits[0] > `1` || b != 'can${digits}' {
					panic('route: bus "${b}" on a [target] kind="threadx" gateway must be named exactly ' +
						'"can0" or "can1" — the comm thread opens buses by that one-digit FDCAN index ' +
						'(a name like "aux0" would map to the wrong instance), and FDCAN3/idx 2 exists only ' +
						'on the 3-FDCAN parts, which this generator cannot tell from the 2-FDCAN ones')
				}
			}
			// A raw target forward copies bytes verbatim: unlike the host signal-route path it
			// cannot VERIFY a protected source or RE-STAMP a protected destination, so a bad frame
			// forwards unverified and freshness/counter/MAC replay. Reject a protected endpoint.
			if m.frames.e2e_here(frof, r.from_bus) || m.frames.secoc_here(frof, r.from_bus)
				|| m.frames.e2e_here(tof, r.to_bus) || m.frames.secoc_here(tof, r.to_bus) {
				panic('route: signal "${r.signal}" on a [target] kind="threadx" gateway touches an ' +
					'E2E/SecOC-protected frame — the raw target forwarder copies bytes and cannot ' +
					'verify/re-protect; route it on the host target')
			}
			// The raw forwarder re-emits on RECEIPT (source cadence). A differing destination
			// cadence would mis-rate (a 10 ms source into a 100 ms dest sends 10x too often).
			// raw_ident only checks layout, so enforce equal cadence here — against the EFFECTIVE
			// destination cadence: an authored [[frame]].tx.cycle_ms OVERRIDES the DBC
			// GenMsgCycleTime, so equal DBC cycles alone would miss a mis-rate (the forwarder
			// ignores the authored cadence and the user's intended rate is silently dropped).
			dest_authored_us := m.frames.tx_cycle_us[tof] or { 0 }
			dest_eff_ms := if dest_authored_us > 0 { dest_authored_us / 1000 } else { r.to_cyc }
			if r.from_cyc != dest_eff_ms {
				panic('route: signal "${r.signal}" on a [target] kind="threadx" gateway has source ' +
					'cadence ${r.from_cyc} ms != effective destination cadence ${dest_eff_ms} ms ' +
					'(an authored [[frame]].tx.cycle_ms overrides the DBC cycle) — the raw forwarder ' +
					're-emits at the source rate; use matching cycle times or route on the host target')
			}
		}
		// both endpoints must name a DECLARED [bus.*]; emit_bridges iterates declared
		// buses only, so a misspelled endpoint silently drops the route.
		if r.from_bus !in m.buses || r.to_bus !in m.buses {
			panic('route: signal "${r.signal}" names an undeclared bus (from "${r.from_bus}", to "${r.to_bus}") — both must be a [bus.*]')
		}
		// Same-core: the forwarder runs in the SOURCE bus's bridge and sends directly on the
		// destination channel. Cross-core: generated as the sanctioned crossing instead — the
		// value rides an IOC channel to the DESTINATION bridge, which composes and transmits
		// on its own channel (REQ-TOPO-010; frame routes were already rejected at parse).
		// the destination frame must not ALSO be a COM tx frame ON THE SAME BUS — a
		// [[signal]] to a bus makes its DBC message an implicit cyclic transmitter even
		// with no [[frame]].tx (so it is not in m.frames.tx_mode). Two writers of one
		// PDU under one id. (Scope by bus: the same frame on a different bus is a
		// separate on-wire writer domain.)
		for _, si in m.sig_of {
			if !si.rx && si.dbc_msg == tof && si.bus == r.to_bus {
				panic('route: destination frame "${r.to_frame}" is also transmitted by COM signal "${si.name}" on bus "${r.to_bus}" — one writer per frame')
			}
		}
		// a module frame (telemetry today) on the destination bus reserves its CAN id —
		// a routed dest id colliding with it makes the route bridge and the telemetry
		// producer transmit different payloads under one id on one interface.
		// telemetry frames are standard (11-bit), so an EXTENDED destination sharing the
		// numeric id is a distinct on-wire frame — only a same-width (standard) clash collides.
		if m.telem.on && m.telem.bus == r.to_bus && !r.to_ext {
			if r.to_id == int(m.telem.id) || (m.telem.detail_id != 0 && r.to_id == int(m.telem.detail_id)) {
				panic('route: destination id 0x${r.to_id:x} on bus "${r.to_bus}" collides with the [telemetry] id — one writer per id')
			}
		}
		// a PROTECTED source frame is now VERIFIED (E2E check / SecOC verify) before the
		// route decodes it — a bad/replayed/tampered frame leaves the value stale, so the
		// freshness deadline suppresses the destination (REQ-TOPO-008). Two limits remain,
		// each a later increment, because the verify runs ONCE per source frame and each
		// verify advances the replay counter:
		if m.frames.e2e_here(frof, r.from_bus) || m.frames.secoc_here(frof, r.from_bus) {
			// (a) a protected source may feed exactly ONE route — composing several routed
			//     signals out of one protected frame would verify (and counter-advance) twice.
			mut nroutes := 0
			for r2 in m.routes {
				if r2.signal != '' && snake(r2.from_frame) == frof && r2.from_bus == r.from_bus {
					nroutes++
				}
			}
			if nroutes > 1 {
				panic('route: protected source frame "${r.from_frame}" feeds ${nroutes} routes — a protected source may feed only ONE (its verify runs once per frame); split it or use an unprotected source')
			}
			// (b) it must not ALSO be a normal COM frame on the same bus — whether an rx
			//     signal reads it (both paths would verify + double-advance the counter) or
			//     a tx signal transmits it (the tx state already declares secoc_key_<frame>,
			//     which the source-verify state would redeclare). Reject either; shared
			//     verify / shared key with a route is a later increment.
			for _, si in m.sig_of {
				if si.dbc_msg == frof && si.bus == r.from_bus {
					dir := if si.rx { 'read' } else { 'transmitted' }
					panic('route: protected source frame "${r.from_frame}" is also ${dir} by COM signal "${si.name}" on the same bus — a protected frame shared by a route and a signal is a later increment')
				}
			}
		}
		// the dest producer stamps protection AFTER composing the routed value, so a routed
		// signal must not occupy any protection byte or it would be overwritten (corrupt
		// data on the wire). Reject the overlap: the E2E CRC byte + counter low-nibble, or
		// the SecOC freshness + MAC bytes, vs this route's dest signal bit span. (Bus-scoped:
		// protection applies only on the frame's authored bus, so use e2e_here/secoc_here.)
		// a routed signal is guaranteed LITTLE-ENDIAN (parse_routes rejects Motorola BEFORE
		// setting to_bit/to_len), so [to_bit, to_bit+to_len) is exactly its occupied bit set.
		if r.to_len > 0 {
			slo, shi := r.to_bit, r.to_bit + r.to_len // [slo, shi) the routed signal's bits
			mut clash := ''
			if m.frames.e2e_here(tof, r.to_bus) {
				cb := (m.frames.e2e_crc[tof] or { 0 }) * 8
				nb := (m.frames.e2e_ctr[tof] or { 0 }) * 8
				if slo < cb + 8 && shi > cb {
					clash = 'the E2E CRC byte'
				} else if slo < nb + 4 && shi > nb {
					clash = 'the E2E counter nibble' // low nibble; high nibble is free
				}
			}
			if m.frames.secoc_here(tof, r.to_bus) {
				fb := (m.frames.secoc_fresh[tof] or { 0 }) * 8
				mlo := (m.frames.secoc_mac[tof] or { 0 }) * 8
				mhi := mlo + (m.frames.secoc_maclen[tof] or { 0 }) * 8
				if slo < fb + 8 && shi > fb {
					clash = 'the SecOC freshness byte'
				} else if slo < mhi && shi > mlo {
					clash = 'the SecOC MAC bytes'
				}
			}
			if clash != '' {
				panic('route: signal "${r.signal}" occupies ${clash} of destination frame "${r.to_frame}" — the producer would overwrite it when it re-protects; move the signal off the protection bytes')
			}
		}
		// the routed producer composes + re-emits every tick; should_send handles cyclic
		// (rate adaptation), but TRIGGERED needs a trigger() no route makes and EVENT change-
		// tracking fights freshness suppression — restrict a routed dest frame to CYCLIC.
		if mode := m.frames.tx_mode[tof] {
			if mode != 'cyclic' {
				panic('route: destination frame "${r.to_frame}" [[frame]].tx.mode = "${mode}" — a routed frame re-emits cyclically only (event/mixed/triggered are a later refinement)')
			}
		}
		// the EFFECTIVE cadence (authored [[frame]].tx.cycle_ms if present, else the DBC
		// GenMsgCycleTime) must be at least the 10 ms comm-bridge tick.
		// an authored [[frame]].tx with no cycle_ms inserts 0; treat 0 as absent.
		authored_us := m.frames.tx_cycle_us[tof] or { 0 }
		eff_us := if authored_us > 0 {
			authored_us
		} else if r.to_cyc > 0 {
			r.to_cyc * 1000
		} else {
			100000
		}
		if eff_us < 10000 {
			panic('route: destination frame "${r.to_frame}" cadence ${eff_us} us is below the 10 ms comm-bridge tick')
		}
	}
	// every destination (bus, id) must be owned by ONE writer. Multiple SIGNAL routes
	// into the SAME frame compose it; anything else — a raw route (which forwards
	// independently, so even two raw routes at one id collide), or a different
	// signal-route frame — is two on-wire writers under one id.
	mut id_owner := map[string]string{}
	for r in m.routes {
		key := '${r.to_bus}/${r.to_id}/${r.to_ext}' // std and ext at the same numeric id are distinct on-wire writers
		// a raw route is a UNIQUE writer: give each its own owner token so any share
		// (raw+raw, raw+signal) trips the collision; signal routes share the frame name.
		owner := if r.signal == '' { 'raw:${r.from_frame}@${r.from_bus}' } else { 'sig:${r.to_frame}' }
		if prev := id_owner[key] {
			if prev != owner || r.signal == '' {
				panic('route: destination id 0x${r.to_id:x} on bus "${r.to_bus}" has two on-wire writers ("${prev}" vs "${owner}") — one writer per id (only signal routes into one frame compose)')
			}
		} else {
			id_owner[key] = owner
		}
	}
	// all signal routes composing ONE destination frame must originate on the SAME source
	// bus — each source bridge composes independently, so a two-bus frame ships two halves.
	mut frame_src := map[string]string{}
	for r in m.routes {
		if r.signal == '' {
			continue
		}
		key := '${r.to_bus}/${r.to_frame}'
		if prev := frame_src[key] {
			if prev != r.from_bus {
				panic('route: destination frame "${r.to_frame}" on "${r.to_bus}" is composed from two source buses ("${prev}" and "${r.from_bus}")')
			}
		} else {
			frame_src[key] = r.from_bus
		}
	}
	// every EXTERNAL signal's frame on a CAN bus — COM tx and rx, host and target, before any of
	// those paths splits — fits its bus (frame_len_refusal, the one rule)
	for _, si in m.sig_of {
		if !si.external || (m.bus_kind[si.bus] or { 'can' }) != 'can' {
			continue
		}
		if why := frame_len_refusal(si.dbc_dlc, bus_fd[si.bus] or { false }) {
			panic('signal "${si.name}": frame "${si.dbc_msg}" on bus "${si.bus}" is ${why}')
		}
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
	ncores       int // cores in the CpuLoad frame (default 1); >1 when the owner aggregates satellites
	det_ovr      string
	det_lines    []string
	frame        string
	detframe     string
	idx          string
}

interface Producer {
	// The partition superloop is one skeleton; each producer injects at four points, keyed by
	// 'p:<partition>' ('b:<bus>' for a bridge, 'io' for the io thread). preamble runs once before the loop; loop_top and
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
	g << '\t\t\tframe := telem.encode_cpuload(load, ${if ctx.ncores > 0 { ctx.ncores } else { 1 }})'
	g << '\t\t\tmut ${ctx.frame} := can.Frame{'
	g << '\t\t\t\tid:  u32(0x${t.id.hex()})'
	g << '\t\t\t\tlen: 8'
	g << '\t\t\t}'
	g << '\t\t\tfor ${ctx.idx} in 0 .. 8 {'
	g << '\t\t\t\t${ctx.frame}.data[${ctx.idx}] = frame[${ctx.idx}]'
	g << '\t\t\t}'
	g << '\t\t\tch.send(${ctx.frame})'
	if t.detail_id != 0 {
		g << '\t\t\tdetail_due = true'
	}
	g << '\t\t}'
	if t.detail_id != 0 {
		// LoadDetail is its OWN pending frame, not a second send inside the CpuLoad block: the
		// CpuLoad send may take the last free FIFO slot (a trace dump or a busy bus keeps it
		// nearly full), and a detail that failed there waited a whole period. It is retried every
		// pass, under the same gate, until accepted. last_overruns advances ONLY on an accepted
		// frame, so the overrun delta is never deducted from a report that never left (emb#259 r1).
		g << '\t\tif detail_due${ctx.gate} {'
		g << '\t\t\tovr := ${ctx.det_ovr}'
		g << ctx.det_lines
		g << '\t\t\tmut ${ctx.detframe} := can.Frame{'
		g << '\t\t\t\tid:  u32(0x${t.detail_id.hex()})'
		g << '\t\t\t\tlen: 8'
		g << '\t\t\t}'
		g << '\t\t\tfor ${ctx.idx} in 0 .. 8 {'
		g << '\t\t\t\t${ctx.detframe}.data[${ctx.idx}] = detail[${ctx.idx}]'
		g << '\t\t\t}'
		g << '\t\t\tif ch.send(${ctx.detframe}) {'
		g << '\t\t\t\tlast_overruns = ovr'
		g << '\t\t\t\tdetail_due = false'
		g << '\t\t\t}'
		g << '\t\t}'
	}
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
	// IO POINTS continue the same global numbering, right after the FB handlers (#263): with
	// [trace] level = "all" the io thread emits one record per point service, and these rows are
	// what a dump resolves them through. Emitted whenever the node HAS io points, so a manifest
	// never advertises an id it cannot name — a trace-less build simply has no records to match.
	if m.io_points.len > 0 {
		for pt in m.io_points {
			man << '${hid},io,${m.io_core},io,${pt.name},${pt.period_ms * 1000},io'
			hid++
		}
	}
	man << '# threads: thread,id,name,core,prio  (id 0 reserved = idle; prio - = no RTOS prio)'
	mut tid := 1
	// ThreadX comm thread (phase 6b-2): AUTO_START at priority 1 — strictly higher than the FB
	// thread and above the still-suspended system timer thread — so at kernel entry it is the
	// FIRST thread the scheduler runs. trace_hooks.c assigns ids by first sight, so the comm
	// thread takes id 1, ahead of the app thread (id 2) and the timer (id 3). Emit it first to
	// match that observed order, else its records are mislabelled / shift the other lanes.
	// min FB priority + local thread count: the comm/io platform-thread priorities are
	// DERIVED in the target emit (comm = min(app) - 1, shifted one more when the io
	// thread sits between comm and the FBs; historical 1 for single-thread) — recompute
	// them here so the manifest shows the real numbers.
	mut mp := 32
	for pn, thrs in m.part.threads_of {
		if m.part.external[pn] {
			continue // the platform threads compete only with their OWN core's threads
		}
		for thr in thrs {
			pr := m.part.thread_prio[thr] or { 10 }
			if pr < mp {
				mp = pr
			}
		}
	}
	mut nthr := 0
	for pn, thrs in m.part.threads_of {
		if !m.part.external[pn] {
			nthr += thrs.len
		}
	}
	io_shift := if m.io_points.len > 0 { 1 } else { 0 }
	if comm_thread_on {
		cp := if nthr > 1 { mp - 1 - io_shift } else { 1 }
		man << 'thread,${tid},comm,${m.part.core_of[single_part] or { 0 }},${cp}'
		tid++
	}
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		if m.part.external[pname] {
			continue // external cores get their OWN per-core id sequence below
		}
		for tname in m.part.threads_of[pname] {
			man << 'thread,${tid},${tname},${m.part.core_of[pname]},${m.part.thread_prio[tname] or { 10 }}' // name = the globally-unique thread name
			tid++
		}
	}
	// The platform io thread on the ThreadX target (docs/io.md): comm > io > FB threads
	// (io = comm + 1 with a comm thread, min FB - 1 without). Row before the kernel
	// timer, matching the deterministic trace-bind order in tx_application_define.
	if m.io_points.len > 0 && m.target.threadx {
		mut iop := mp - 1
		if comm_thread_on && nthr <= 1 {
			iop = 2 // single-thread comm keeps the historical 1; io just below it
		}
		man << 'thread,${tid},io,${m.io_core},${iop}'
		tid++
	}
	// The eth comm thread (docs/someip.md target rung): bound after io, before
	// the kernel timer — matching the trace-bind order in tx_application_define.
	if eth_thread_on(m) {
		mut ep := mp - 2 // no CAN comm thread: io sits at mp-1, the eth owner one above
		if comm_thread_on {
			ep = if nthr > 1 { mp - 1 - io_shift } else { 1 } // created at the comm level
		}
		man << 'thread,${tid},eth,${m.bus_core[m.eth] or { 0 }},${ep}'
		tid++
	}
	// the DoIP transport's threads (gen_doip.v): bound after eth, before the kernel timer
	if comm_thread_on {
		doip_rows := doip_manifest_rows(m, tid)
		man << doip_rows
		tid += doip_rows.len
	}
	timer_rows := trace_manifest_timer_row(m, tid)
	man << timer_rows
	tid += timer_rows.len
	// boards/common/trace_hooks.c binds MAX_THREADS (8) ids; past that a thread records as id 0
	// while the manifest names a higher one — refuse rather than mislabel the trace
	if timer_rows.len > 0 && tid - 1 > trace_max_threads {
		panic('loom2v: [trace] on this ThreadX image needs ${tid - 1} thread ids, but the recorder ' +
			'(boards/common/trace_hooks.c MAX_THREADS) binds ${trace_max_threads} — fewer threads, or no [trace]')
	}
	// EXTERNAL partitions (satellite cores): thread ids are PER-CORE — the satellite's own
	// recorder assigns first-sight ids from 1, so its records carry 1..N regardless of what
	// this core numbers. Consumers key threads by (core, id); rows here mirror the satellite's
	// bind order (priority order, then its kernel timer) exactly as core 0's rows mirror ours.
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		if !m.part.external[pname] {
			continue
		}
		xcore := m.part.core_of[pname]
		mut xtid := 1
		for tname in m.part.threads_of[pname] {
			man << 'thread,${xtid},${tname},${xcore},${m.part.thread_prio[tname] or { 10 }}'
			xtid++
		}
		if m.target.threadx && m.trace.on {
			man << 'thread,${xtid},tx_system_timer,${xcore},0'
		}
	}
	// Comm threads (P3b): one per bridge bus, AFTER the app threads (matches the gate's comm_tid
	// numbering).
	for bb in bridge_bus_list {
		man << 'thread,${tid},comm_${bb},${m.bus_core[bb] or { 0 }},-' // host threads: no RTOS prio
		tid++
	}
	// The HOST platform io thread (docs/io.md): trace-visible by name, like the comm
	// threads (no RTOS prio). The ThreadX target emitted its row above, with the prio.
	if m.io_points.len > 0 && !m.target.threadx {
		man << 'thread,${tid},io,${m.io_core},-'
		tid++
	}
	man << trace_manifest_frames(m)
	man << shell_manifest_frames(m)
	man << nm_manifest_frames(m)
	man << xcore_manifest(m)
	man << nvm_manifest(m)
	man << param_manifest(m)
	man << someip_manifest(m)
	return man
}

// emit_partition_telem emits the host CpuLoad tx thread: sum each core's per-partition load from
// the scratch slots and ship it as a CpuLoad frame every period. Host only — the target and
// inline-trace modes send CpuLoad inline from run(). Returns the glue lines, or none when the
// telemetry-tx thread doesn't apply. (slot_core / telem_iface / trace_inline are main's emit-time
// derived state; everything else comes from the Model.)
fn emit_partition_telem(m Model, telem_iface string, slot_core []int, trace_owns_run bool) []string {
	// trace_owns_run means an APP-PARTITION trace runner replaced run() and sends CpuLoad inline;
	// the P3b bridge owner did not — gen.v passes false for it, keeping this thread.
	if !(telem_on_can(m) && telem_iface != '' && !m.target.on && !trace_owns_run) {
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
		mut local_parts := []string{}
		for pname, _ in m.part.core_of {
			if !m.part.external[pname] {
				local_parts << pname
			}
		}
		if local_parts.len != 1 {
			panic('loom2v: [target] generates exactly one LOCAL partition (got ${local_parts.len}) — ' +
				'additional cores are declared with external = true (their images are provided ' +
				'elsewhere; the full multi-image emitter absorbs them later)')
		}
		part := local_parts[0]
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
		if m.target.threadx && !(m.io_points.len > 0 && m.buses.len == 0) && !eth_only_img(m) {
			// (the bus-index derivation is skipped entirely for a bus-less
			// [[io.gpio]]-only node and an eth-only node — both app entries are
			// channel-free; the eth thread opens a socket, not an FDCAN index)
			if bc := doc.value('bus').as_map()[m.telem.bus] {
				tx_bus_fd = (bc.as_map()['fd'] or { toml.Any(false) }).bool()
			}
			// CAN-FD on a generated target: the fdcan backend handles FD framing (h755_canfd) and
			// the pack/unpack paths carry up to com.max_pdu (64) bytes, so a bus.fd = true opens the
			// channel FD (can.v flags every send from Channel.fd). The per-board data-phase timing
			// (BLOB_FDCAN_D*) must be harmonized across every node on the bus — done by giving the
			// FD boards a common PLL2-derived FDCAN kernel clock (boards/*/board.c), which makes the
			// nominal + data timing and the sample points identical by construction. The FD bit
			// timing is BENCH-PENDING on silicon (requirements/verifications.toml
			// system-full-edge-canfd is skip_exit=2 = not-run; CI only proves generate + build). #266.
			_ = tx_bus_fd
			// The driver opens the bus by a SINGLE-digit index "0".."2" (blob_can_open reads
			// name[0]-'0'); derive it from the bus name (e.g. "can0" -> "0"). Require exactly one
			// digit in 0..2 — reject a name with no digit ("powertrain" -> bus 0 silently) OR an
			// ambiguous multi-digit one ("can10"/"can01", where the driver would read only '1'/'0').
			tx_bus_idx = fdcan_index(m.telem.bus)
			if tx_bus_idx == '' {
				panic('loom2v: [target] kind="threadx": telemetry bus "${m.telem.bus}" must name a single ' +
					'FDCAN index 0..2 (e.g. "can0") — the driver opens buses by a one-digit index')
			}
		}
		tx_sleep_ticks := if m.target.tick_us / 1000 > 1 { m.target.tick_us / 1000 } else { u64(1) }
		glue << ''
		glue << 'fn C.board_now_us() u64 // bare-metal monotonic µs (DWT cycle counter)'
		glue << baremetal_trace_globals(m)
		if m.io_points.len > 0 {
			glue << 'fn C.io_exec_add(u32)  // io serve-exec µs, single writer (io thread)'
			glue << 'fn C.io_exec_us() u32 // FB thread reads to subtract io preemption'
		}
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
			if !comm_thread_on && m.io_points.len > 0 {
				// no-comm + io (emb#150 r5): run() publishes its scratch slot and the
				// inline CpuLoad producer reads the sums — the comm branch declares
				// these for itself; this cut needs them here
				glue << 'fn C.load_pub(u32, u32, u32, u32, u32)'
				glue << 'fn C.load_pub_slot(int, u32, u32, u32, u32, u32)'
				glue << 'fn C.load_sum_permille() u32'
				glue << 'fn C.load_sum_100ms() u32'
				glue << 'fn C.load_sum_1s() u32'
				glue << 'fn C.load_sum_10s() u32'
				glue << 'fn C.load_sum_overruns() u32'
			}
			glue << 'fn C._tx_thread_create(voidptr, &char, fn (u32), u32, voidptr, u32, u32, u32, u32, u32) u32'
			glue << trace_c_decls(m)
			glue << shell_c_decls(m)
			glue << xcore_c_decls(m)
			glue << display_c_decls(m)
			if has_satellite(m) {
				// boot() calls this to release the parked satellite. Keyed on has_satellite, NOT
				// xcore_on — a node can own a satellite for [[bulk]]/CpuLoad without any cross-core
				// SIGNAL (the domain), and then xcore_c_decls (xcore_on-gated) emits nothing (codex #235).
				glue << 'fn C.xcore_clocks_ready() // release the parked satellite: final HCLK + HSEM en + XCORE_CLK_MAGIC (xcore.h)'
			}
			glue << nvm_c_decls(m)
			glue << xcore_trace_c_decls(m)
			glue << emit_bulk_service_decls(m.bulk, m.part, '') // owner-side cross-core bulk service
			if comm_thread_on && m.part.image.len > 0 {
				// cross-core CpuLoad: the comm thread reads each satellite core's published load
				glue << "fn C.xcore_load_get(int) u16 // a satellite core's per-mille load (xcore.h; weak 0)"
			}
			glue << shell_cmd_fns(m)
			glue << diag_target_fns(m, ioc_idx)
			glue << diag_target_sa_fns(m)
			glue << diag_target_c_decls(m)
			glue << boot_target_fns(m)
			glue << doip_target_fns(m)
			glue << nm_shell_fns(m)
			glue << stat_shell_fns(m, doc, app_threads, multi)
			glue << trace_fb_hooks(m, doc, app_threads, multi, m.io_points.len > 0)
			if comm_thread_on {
				// Board glue (boards/common/comm_glue.c): the FDCAN Rx-FIFO0 ISR posts a semaphore
				// that comm_rx_wait blocks on, so the comm thread wakes on rx instead of polling.
				// comm_rx_irq_enable arms the Rx interrupt (called once, after the channel opens).
				glue << 'fn C.comm_rx_irq_enable()'
				if m.routes.len > 0 {
					// gateway: arm FDCAN1/2/3 Rx interrupts per route bus (all wake one semaphore)
					glue << 'fn C.comm_rx_irq_enable_idx(int)'
				}
				glue << 'fn C.comm_rx_wait(u32) u32 // block up to N ticks; returns 0 if woken by rx'
				// Load scratch: the FB thread and the comm thread run on different ThreadX threads,
				// so the load cell is published/read through VOLATILE C accessors (comm_glue.c) — V
				// can't emit a volatile global, and a plain one could be cached at -Os so the comm
				// thread ships a stale CpuLoad. Single-writer/single-reader scalars, so no lock.
				if multi {
					glue << 'fn C.load_pub_slot(int, u32, u32, u32, u32, u32)'
				} else {
					glue << 'fn C.load_pub(u32, u32, u32, u32, u32)'
					if m.io_points.len > 0 {
						// the io thread publishes its OWN slot; the FB keeps the slot-0 alias
						glue << 'fn C.load_pub_slot(int, u32, u32, u32, u32, u32)'
					}
				}
				// with an io thread the single-FB cut also reads the SUMS, so io's serve
				// time lands in CpuLoad like every FB thread's does
				if multi || m.io_points.len > 0 {
					glue << 'fn C.load_sum_permille() u32'
					glue << 'fn C.load_sum_100ms() u32'
					glue << 'fn C.load_sum_1s() u32'
					glue << 'fn C.load_sum_10s() u32'
					glue << 'fn C.load_sum_overruns() u32'
				}
				if true {
					glue << 'fn C.load_permille() u32'
					glue << 'fn C.load_100ms() u32'
					glue << 'fn C.load_1s() u32'
					glue << 'fn C.load_10s() u32'
					glue << 'fn C.load_overruns() u32'
				}
			}
			if ioc_idx.len > 0 {
				// Target IOC pool (glue C, wait-free triple-buffer ioc.h): every cross-thread
				// signal rides one indexed cell — comm-decoded rx -> FB (ioc_pub/ioc_get),
				// persist staging, and the io thread's points; ioc_pool_init runs once before
				// the kernel starts.
				glue << 'fn C.ioc_pool_init()'
				glue << 'fn C.ioc_pub(int, u32, u32)'
				glue << 'fn C.ioc_get(int, &u32, &u32)'
				// 1 once the cell has EVER been published (comm_glue.c): the outputs' and the
				// producers' gate, so a cell's zero-init is never taken for a value
				glue << 'fn C.ioc_get_ever(int, &u32, &u32) int'
			}
			if eth_thread_on(m) {
				// the NetX eth seam (driver/eth/eth_netx.c)
				glue << 'fn C.blob_eth_open(&char, u16) int'
				glue << 'fn C.blob_eth_send(int, &u8, u16, &u8, int) int'
				glue << 'fn C.blob_eth_recv(int, &u8, &u16, &u8, int) int'
			}
			if iocb_on(m) {
				// the byte IOC pool (boards/common/iocb.c): struct-bearing eth signals, checked
				// received signals and the fault cells cross threads through size-proportional
				// arenas (boards/common/ioc.h)
				glue << 'fn C.iocb_cfg(int, u16)'
				glue << 'fn C.iocb_pub(int, voidptr)'
				glue << 'fn C.iocb_get(int, voidptr)'
				if eth_thread_on(m) {
					glue << 'fn C.iocb_get_ever(int, voidptr) int'
				}
			}
			if m.io_points.len > 0 {
				// io thread plumbing: created AUTO_START OFF + resumed after the boot publish
				// (REQ-IO-009). ioc_get_ever (declared with the pool) is the outputs' freshness gate — 1 once the cell
				// has EVER been published, so the driver-established init holds until the
				// producing FB's first publish (a plain ioc_get would drive the pin with the
				// slot's zero-init).
				glue << 'fn C._tx_thread_resume(voidptr) u32'
			}
			glue << ''
			// TCB as [32]u64 (256 B >= sizeof(TX_THREAD) = 200 B) so it is 8-byte aligned — the
			// kernel reads/writes word fields through this pointer as a TX_THREAD*, so a byte-
			// aligned [256]u8 could fault. The stack stays a byte buffer (ThreadX aligns the SP
			// internally in tx_thread_stack_build).
			glue << rx_target_struct(m)
			glue << '__global ('
			for thr in app_threads {
				own := if multi { thr } else { part }
				glue << '\tg_${own}_tcb   [32]u64  // >= sizeof(TX_THREAD) (200 B), 8-byte aligned'
				glue << '\tg_${own}_stack [4096]u8'
				// The Scheduler lives for the thread's lifetime — as an entry-frame local it would
				// permanently sit under every deeper frame (1.6 KB at the host default of 32 slots;
				// gen/loom_build.mk right-sizes it, but the placement rule doesn't depend on that).
				// bss-zero == Scheduler{} (its only field default is a nil hook), so no init needed.
				glue << '\tg_sched_${own} loom.Scheduler // bss, never an entry-frame local'
			}
			glue << trace_scratch_fields(m, part)
			glue << trace_module_globals(m)
			glue << shell_module_globals(m)
			glue << diag_target_globals(m)
			glue << fault_target_globals(m)
			glue << rx_target_global(m)
			glue << doip_target_globals(m)
			glue << xcore_trace_globals(m)
			glue << nvm_globals(m)
			glue << param_globals(m)
			glue << nm_module_globals(m)
			if comm_thread_on {
				glue << '\tg_comm_tcb   [32]u64  // the bus-owning comm thread'
				// The comm thread hosts EVERY module (COM, trace, shell, NM) and — with
				// [nvm] — the journal put path into the real flash driver. 4 KB was
				// measured paper-thin on the H755 bench (the v4 image faulted with PSP
				// 40 B below the DTCM floor mid-put): 8 KB with [nvm], 4 KB without.
				// the diagnostic server's dispatch copies its ISO-TP link / UDS server by value into
				// several frames (~1 KB each): 8 KB with [isotp] too
				comm_stack := if m.nvm.on || m.isotp_conns.len > 0 { 8192 } else { 4096 }
				glue << '\tg_comm_stack [${comm_stack}]u8'
				// (The load cell is the volatile C scratch in comm_glue.c, via load_pub/load_*.)
				// Rx accounting: the comm thread counts received frames + keeps the last value, so a
				// host cansend is observable. The rx CONSUMER of the lean cut (comm-thread-local).
				glue << '\tg_rx_count u32'
				glue << '\tg_rx_last  u32'
				if m.routes.len > 0 {
					// gateway: frames forwarded bus->bus (raw copy + id remap). Exported so a
					// bench can confirm the ThreadX gateway is routing (the SWD-observable rule).
					glue << '\tg_fwd_count u32'
				}
			}
			if eth_thread_on(m) {
				glue << '\tg_eth_tcb   [32]u64  // the SOME/IP eth comm thread (docs/someip.md)'
				glue << '\tg_eth_stack [4096]u8 // someip codec + TxState/E2E frames: comm-thread-class depth'
				// drop/ok counters as exported globals: SWD-observable (the
				// semihosting-never rule) — the host bridge prints, silicon counts
				glue << '\tg_eth_rx_ok u32'
				glue << '\tg_eth_rx_drops u32'
			}
			if m.io_points.len > 0 {
				glue << '\tg_io_tcb   [32]u64  // the platform io thread (docs/io.md)'
				glue << '\tg_io_stack [2048]u8 // gpio serve loop only: no modules, shallow frames'
				if comm_thread_on || m.telem.on {
					// load accounting only — the io thread has no handlers; module-sized, so
					// bss. Present whenever ANYONE ships CpuLoad (emb#150 r5: the inline
					// producer counts io too, not just the comm thread's sums).
					glue << '\tg_sched_io loom.Scheduler // io serve-time accounting for the CpuLoad seam'
				}
				// the startup-fault counter is an exported symbol (docs/io.md observability
				// rule): SWD/bench readable even with no service on
				glue << '\tio_startup_faults u32'
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
				glue << '\tmut st := Thread_${thr}_state{} // small + carries the FB field defaults: stack is right'
				glue << nvm_restore_lines(m, nvm_writer_thr(m, doc), thr, true)
				glue << '\tmut sched := &g_sched_${thr} // module-sized: lives in bss, not this lifetime frame'
				for r in all_regs['${part}/${thr}'] or { []string{} } {
					glue << r
				}
				glue << '\ttick_us := u64(${m.target.tick_us})'
				if m.trace.on && m.trace.level == 'all' {
					glue << '\tsched.set_trace_hook(trace_fb_hook_${thr}, unsafe { nil })'
				}
				io_here := m.io_points.len > 0
				glue << '\tfor {'
				glue << '\t\tt0 := C.board_now_us()'
				if io_here {
					// the io thread is HIGHER priority: its execution inside this bracket
					// inflates the wall time. Sample its monotonic exec counter and subtract,
					// so per-thread load is EXECUTION time and the core sum never double-
					// counts io (codex on emb#150 r10).
					glue << '\t\tio0 := C.io_exec_us()'
				}
				if m.trace.on && m.trace.level == 'all' {
					if io_here {
						// per-handler brackets exclude the io thread's preemption via its exec
						// counter (loom.run_profiled_excl) — the same correction as below, per handler
						glue << '\t\tsched.run_profiled_excl(trace_clock, io_exec_clock)'
						glue << '\t\tio_dt := u64(C.io_exec_us() - io0) // BEFORE t1: contained in the bracket (codex #264 r2)'
						glue << '\t\tt1 := C.board_now_us()'
					} else {
						glue << '\t\tsched.run_profiled(trace_clock)'
						glue << '\t\tt1 := C.board_now_us()'
					}
				} else {
					glue << '\t\tsched.run(t0)'
					if io_here {
						glue << '\t\tio_dt := u64(C.io_exec_us() - io0) // BEFORE t1 (codex #264 r2)'
					}
					glue << '\t\tt1 := C.board_now_us()'
					if io_here {
						glue << '\t\tfb_busy := if t1 - t0 > io_dt { t1 - t0 - io_dt } else { u64(0) }'
						glue << "\t\tsched.account(fb_busy, t1) // handler time (io preemption excluded)"
					} else {
						glue << "\t\tsched.account(t1 - t0, t1) // handler time -> this thread's load"
					}
				}
				if io_here {
					glue << '\t\tpass_us := if t1 - t0 > io_dt { t1 - t0 - io_dt } else { u64(0) }'
					glue << '\t\tif pass_us > tick_us { // OWN work exceeded the tick (io excluded)'
					glue << '\t\t\tsched.mark_overrun()'
					glue << '\t\t}'
				} else {
					glue << '\t\tif t1 - t0 > tick_us { // pass exceeded its tick budget -> overrun'
					glue << '\t\t\tsched.mark_overrun()'
					glue << '\t\t}'
				}
				glue << '\t\tC.load_pub_slot(${ti}, u32(sched.load_permille()), u32(sched.load_permille_100ms()),'
				glue << '\t\t\tu32(sched.load_permille_1s()), u32(sched.load_permille_10s()), sched.overruns())'
				glue << '\t\tC._tx_thread_sleep(u32(${tx_sleep_ticks}))'
				glue << '\t}'
				glue << '}'
				glue << ''
			}
		}
		if !multi && part !in m.part.by_part {
			// FB-less local partition (a pure gateway: the comm thread does all the work,
			// the app thread just idles). emit_handlers only emits the state struct for
			// FB-bearing partitions, but run() below still instantiates it — emit the empty
			// struct here so the idle thread's run() compiles.
			glue << 'struct Partition_${part}_state {}'
			glue << ''
		}
		if !multi && (comm_thread_on || m.buses.len == 0 || eth_only_img(m)) {
			// The FB thread stays OFF CAN: with a comm thread it owns the bus, a
			// bus-less [[io.gpio]]-only node has no channel at all (emb#150 r4),
			// and an eth-only node's bus is the eth thread's socket, not a channel.
			// run() just dispatches the FBs and publishes load to the scratch cell.
			glue << 'pub fn run() {'
		} else if !multi {
			glue << 'pub fn run(${chp} can.Channel) {'
			glue << '\tmut ch := ${chp}'
		}
		if !multi {
		glue << '\tmut st := Partition_${part}_state{}'
		if m.target.threadx {
			glue << nvm_restore_lines(m, nvm_writer_thr(m, doc), '', false)
			for fb in fault_fbs(m) {
				glue << fault_init_lines(m, fb)
			}
		}
		if m.target.threadx {
			// same rule as the multi-thread path: the FB thread has a 4 KB stack. Bare metal
			// keeps the local — run() sits on the main stack, which owns the remaining RAM.
			glue << '\tmut sched := &g_sched_${part} // module-sized: lives in bss, not this lifetime frame'
		} else {
			glue << '\tmut sched := loom.Scheduler{}'
		}
		for r in all_regs[part] or { []string{} } {
			glue << r
		}
		if m.telem.on && telem_iface != '' && !comm_thread_on {
			glue << '\tmut load := [8]u16{}'
			glue << '\ttelem_period_us := u64(${m.telem.period_us})'
			glue << '\tmut last_telem := u64(0)'
			if m.telem.detail_id != 0 {
				glue << '\tmut last_overruns := u32(0) // for the per-period overrun count'
				glue << '\tmut detail_due := false // LoadDetail owed until the FIFO accepts it'
			}
		}
		glue << '\ttick_us := u64(${m.target.tick_us})'
		if !m.target.threadx {
			glue << '\tmut next_tick := C.board_now_us() + tick_us'
		}
		glue << trace_fb_install(m)
		glue << baremetal_trace_init(m)
		fb_io := m.io_points.len > 0 // subtract higher-prio io preemption from the wall bracket
		glue << '\tfor {'
		glue << '\t\tt0 := C.board_now_us()'
		if fb_io {
			// read the io exec baseline immediately after t0 (and the endpoint immediately
			// after t1): the io thread could preempt in that instruction-width gap, so the
			// correction has a residual bounded by ONE io serve (sub-µs, below the µs
			// telemetry resolution). A fully atomic core-load would need a single idle-time
			// source (an idle accountant thread) — the eventual clean model (codex emb#150 r11).
			glue << '\t\tio0 := C.io_exec_us() // io is higher priority: exclude its preemption'
		}
		if m.trace.on && (m.trace.level == 'all' || baremetal_trace_on(m)) {
			// profiled dispatch: run_profiled accounts internally and fires the FB trace hook
			if fb_io {
				glue << '\t\tsched.run_profiled_excl(trace_clock, io_exec_clock)'
				glue << '\t\tio_dt := u64(C.io_exec_us() - io0) // BEFORE t1: contained in the bracket (codex #264 r2)'
				glue << '\t\tt1 := C.board_now_us()'
			} else {
				glue << '\t\tsched.run_profiled(trace_clock)'
				glue << '\t\tt1 := C.board_now_us()'
			}
		} else {
			glue << '\t\tsched.run(t0)'
			if fb_io {
				glue << '\t\tio_dt := u64(C.io_exec_us() - io0) // BEFORE t1 (codex #264 r2)'
			}
			glue << '\t\tt1 := C.board_now_us()'
			if fb_io {
				glue << '\t\tfb_busy := if t1 - t0 > io_dt { t1 - t0 - io_dt } else { u64(0) }'
				glue << "\t\tsched.account(fb_busy, t1) // handler time, io preemption excluded (emb#150 r10)"
			} else {
				glue << "\t\tsched.account(t1 - t0, t1) // handler time -> this core's load"
			}
		}
		if fb_io {
			glue << '\t\tpass_us := if t1 - t0 > io_dt { t1 - t0 - io_dt } else { u64(0) }'
			glue << '\t\tif pass_us > tick_us { // OWN work over budget (io excluded)'
			glue << '\t\t\tsched.mark_overrun()'
			glue << '\t\t}'
		} else {
			glue << '\t\tif t1 - t0 > tick_us { // pass exceeded its tick budget -> overrun'
			glue << '\t\t\tsched.mark_overrun()'
			glue << '\t\t}'
		}
		if comm_thread_on || (m.target.threadx && m.io_points.len > 0) {
			// Publish this core's load to the volatile scratch (single writer) — for the
			// comm thread's CpuLoad producer, or (no-comm + io, emb#150 r5) so the inline
			// producer's load_sum sees the app slot next to the io thread's slot.
			glue << '\t\tC.load_pub(u32(sched.load_permille()), u32(sched.load_permille_100ms()),'
			glue << '\t\t\tu32(sched.load_permille_1s()), u32(sched.load_permille_10s()), sched.overruns())'
		}
		for p in producers {
			glue << p.bus_tick(BusCtx{
				telem_active: m.telem.on && telem_iface != '' && !comm_thread_on
				now:          't1'
				period:       'telem_period_us'
				// gated like the comm-thread model above: a full Tx FIFO (a trace burst, a busy
				// bus) makes an ungated send() drop the frame and say nothing. last_telem stays
				// un-updated, so the frame is still due on the next pass (emb#252).
				gate:         ' && ch.tx_ready()'
				load:         [if m.io_points.len > 0 {
				// the io thread publishes its slot to the scratch; run() publishes
				// slot 0 — the sum is the core's whole truth (emb#150 r5)
				'\t\t\tload[0] = u16(C.load_sum_permille())'
			} else {
				if baremetal_trace_on(m) {
					// traced: the slot the trace module reports (single_trace_core), so CpuLoad
					// and the dump name the same core
					'\t\t\tload[${single_trace_core(m)}] = sched.load_permille() // this partition\'s core'
				} else {
					'\t\t\tload[0] = sched.load_permille() // single M7 -> core 0 only'
				}
			}]
				ncores:       if baremetal_trace_on(m) { single_trace_core(m) + 1 } else { 0 }
				det_ovr:      if m.io_points.len > 0 {
					'C.load_sum_overruns()' // io overruns count too (emb#150 r6)
				} else {
					'sched.overruns()'
				}
				det_lines:    if m.io_points.len > 0 {
					// io accounts too: the detail frame reads the SUMS, matching CpuLoad (emb#150 r6)
					['\t\t\tdetail := telem.encode_loaddetail(u16(C.load_sum_100ms()),', '\t\t\t\tu16(C.load_sum_1s()), u16(C.load_sum_10s()), ovr - last_overruns)']
				} else {
					['\t\t\tdetail := telem.encode_loaddetail(sched.load_permille_100ms(),', '\t\t\t\tsched.load_permille_1s(), sched.load_permille_10s(), ovr - last_overruns)']
				}
				frame:        'f'
				detframe:     'd'
				idx:          'i'
			})
		}
		// AFTER telemetry: the CpuLoad + LoadDetail pair takes the Tx FIFO first, so a dump
		// burst filling it cannot starve the second of the two frames.
		glue << baremetal_trace_bus(m)
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
			// io load slot = the one after the FB threads (its manifest row's position);
			// only the comm-thread target has the load scratch seam to publish into.
			// io load accounting runs whenever ANYONE ships CpuLoad — the comm thread
			// (scratch sums) or the inline producer (no-comm telemetry, emb#150 r5);
			// without it the io thread's serve time vanishes from telemetry.
			glue << emit_io_target_entry(m, doc, ioc_idx, comm_thread_on || m.telem.on, app_threads.len)
			if comm_thread_on {
				// The comm thread must be STRICTLY higher priority (lower number) than the FB thread
				// so it preempts a long app pass to drain rx after the ISR posts (zero time slice
				// means no round-robin). With comm fixed at 1, the app thread must be >= 2.
				if min_prio <= 1 {
					panic('loom2v: [target] kind="threadx" comm thread needs a priority strictly higher ' +
						'than every FB thread, but the highest FB priority is ${min_prio}; use ' +
						'priorities >= 2 so the comm owner preempts them to drain rx promptly')
				}
				// With io points, TWO platform threads outrank the FBs — comm, then the io
				// thread just below it (comm still drains rx first; io still preempts every
				// FB to hold its cadence) — so the multi derivation shifts comm one more up
				// and the FBs need priorities >= 3.
				if m.io_points.len > 0 && min_prio <= 2 {
					panic('loom2v: [target] kind="threadx" with [[io.gpio]]: comm > io > FB threads, ' +
						'but the highest FB priority is ${min_prio}; use priorities >= 3')
				}
				io_shift := if m.io_points.len > 0 { 1 } else { 0 }
				// Single-thread keeps the historical comm priority 1; multi-thread derives it as
				// min(app priorities) - 1, so realistic numbering (apps 11/12/13 -> comm 10) works
				// without a separate config knob and comm ALWAYS outranks the apps.
				comm_prio := if multi { min_prio - 1 - io_shift } else { 1 }
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
				rx_checked := rx_checked_msgs(m)
				for sn in m.sig_names {
					s := m.sig_of[sn] or { continue }
					if m.eth != '' && s.bus == m.eth {
						continue // eth signals ride the eth thread, not the CAN drain
					}
					if s.dbc_msg in rx_checked {
						continue // checked: rx_target_arms below
					}
					if s.rx && !rx_ids_seen[s.dbc_id] {
						rx_ids_seen[s.dbc_id] = true
						rx_sigs << s
					}
				}
				// external TX signals (FB writes -> IOC -> comm sends), a producer each. REMOTE
				// tx signals (satellite -> bus) ride the xioc drain (xcore_produce_drain) instead.
				mut tx_sigs := []SigInfo{}
				for sn in m.sig_names {
					s := m.sig_of[sn] or { continue }
					if m.eth != '' && s.bus == m.eth {
						continue // eth signals ride the eth thread, not the CAN producer
					}
					if s.external && !s.rx && !s.remote {
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
				// the io thread publishes its own slot, so its presence flips the single-FB
				// cut onto the summed reads too (io serve time counts like an FB thread's)
				sum_load := multi || m.io_points.len > 0
				mut comm_load_line := if sum_load {
					'\t\t\tload[0] = u16(C.load_sum_permille()) // sum of the FB threads (one core)'
				} else {
					'\t\t\tload[0] = u16(C.load_permille())'
				}
				mut comm_ncores := 1
				for spart, _ in m.part.image {
					sc := m.part.core_of[spart] or { continue }
					comm_load_line += '\n\t\t\tload[${sc}] = C.xcore_load_get(${sc}) // ' + spart + ' satellite (cross-core)'
					if sc + 1 > comm_ncores {
						comm_ncores = sc + 1
					}
				}
				comm_det_ovr := if sum_load { 'C.load_sum_overruns()' } else { 'C.load_overruns()' }
				comm_det_line := if sum_load {
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
				// GATEWAY: open a channel for every OTHER route bus (the telem bus is `ch`),
				// and arm its FDCAN Rx interrupt into the SAME wake semaphore (comm_glue.c). The
				// comm loop then drains all of them each wake and forwards raw_ident routes.
				gw_extra := gateway_extra_buses(m)
				for b in gw_extra {
					bidx := fdcan_index_of(b)
					bfd := if bc := doc.value('bus').as_map()[b] {
						(bc.as_map()['fd'] or { toml.Any(false) }).bool()
					} else {
						false
					}
					glue << '\tmut ch_${snake(b)} := can.Channel{} // gateway route bus ${b}'
					glue << "\tif !ch_${snake(b)}.open('${bidx}', ${bfd}) { // board must init FDCAN${bidx.int() + 1} pins for silicon"
					glue << '\t\tfor { C._tx_thread_sleep(1000) } // dead route bus — park'
					glue << '\t}'
					glue << '\tC.comm_rx_irq_enable_idx(${bidx}) // wake the comm thread on this bus too'
				}
				if m.telem.on && telem_iface != '' {
					glue << '\tmut last_telem := u64(0)'
					glue << '\ttelem_period_us := u64(${m.telem.period_us})'
					if m.telem.detail_id != 0 {
						glue << '\tmut last_overruns := u32(0)'
						glue << '\tmut detail_due := false // LoadDetail owed until the FIFO accepts it'
					}
				}
				glue << trace_module_init(m)
				glue << shell_module_init(m)
				glue << diag_target_init(m)
				glue << fault_target_init(m)
				glue << rx_target_init(m)
				glue << doip_target_init(m)
				glue << param_bind_lines(m)
				glue << nm_shell_register(m)
				glue << stat_shell_register(m)
				glue << nm_module_init(m)
				glue << fault_target_cycle_boot(m)
				glue << xcore_comm_locals(m)
				glue << nvm_comm_locals(m, ioc_idx)
				glue << xcore_trace_locals(m)
				for si in tx_sigs {
					glue << '\tmut last_tx_${snake(si.name)} := u64(0)'
				}
				if target_encodes(m) {
					glue << '\tmut tx_sat := com.TxSaturations{} // sent values com.encode_raw saturated (docs/communication.md)'
				}
				glue << '\tmut rx := can.Frame{}'
				glue << '\tfor {'
				// While a stream is in flight — a trace dump, a diagnostic answer — wake every tick:
				// the Tx FIFO holds ~3 frames, so a 10-tick pace stretches a 75-frame block to
				// ~300 ms (blowing host budgets); at 1 tick it drains in ~25 ms.
				mut streaming := []string{}
				if m.trace.on {
					streaming << 'g_tm.is_dumping()'
				}
				if m.isotp_conns.len > 0 {
					streaming << 'g_diag.link.busy()'
				}
				if streaming.len > 0 {
					glue << '\t\twait_ticks := if ${streaming.join(' || ')} { u32(1) } else { u32(10) }'
					glue << '\t\tC.comm_rx_wait(wait_ticks) // the FDCAN Rx ISR wakes us early on a new frame'
				} else {
					glue << '\t\tC.comm_rx_wait(10) // block up to 10 ticks; the FDCAN Rx ISR wakes us on a new frame'
				}
				// the pass, in the ONE order comm_pass_order states (gen_rx_target.v)
				for step in comm_pass_order {
					// a step this node has nothing for leaves no marker
					at := glue.len
					glue << '\t\t// pass: ${step}'
					match step {
						.housekeep {
							glue << diag_target_housekeep(m)
						}
						.open {
							glue << rx_target_top(m)
						}
						.reports {
							glue << fault_target_pass(m)
						}
						.remote {
							glue << doip_target_serve(m)
							if m.doip.on {
								glue << rx_target_resample(m, '\t\t')
							}
						}
						.drain {
							glue << comm_nm_seen(m)
						glue << '\t\t// CONSUMER: drain the Rx FIFO (non-blocking); account each external rx frame'
						glue << '\t\tfor ch.recv(mut rx) {'
						for si in rx_sigs {
							// Gate on the DBC DLC too: recv reuses the frame and copies only the bytes that
							// arrived, so a short same-id frame would leave stale high bytes in the decode.
							glue << '\t\t\tif rx.id == u32(0x${si.dbc_id.hex()}) && rx.len == ${si.dbc_dlc} && rx.ext == ${si.dbc_ext} { // ${si.dbc_msg}'
							glue << '\t\t\t\tg_rx_count++'
							glue << '\t\t\t\tg_rx_last = u32(rx.data[0]) | (u32(rx.data[1]) << 8) | (u32(rx.data[2]) << 16) | (u32(rx.data[3]) << 24)'
							if idx := msg_ioc_idx[si.dbc_id] {
								// This message carries an FB-read signal (keyed by DBC id, so it fires even when
								// the de-duped representative is a different, un-read signal): publish the decoded
								// value (byte-0 scalar) into its IOC cell so the app thread picks it up wait-free
								// — while 0x28 has reception on.
								if m.isotp_conns.len > 0 {
									glue << '\t\t\t\tif st.rxg.on {'
									glue << '\t\t\t\t\tC.ioc_pub(${idx}, g_rx_last, u32(0))'
									glue << '\t\t\t\t}'
								} else {
									glue << '\t\t\t\tC.ioc_pub(${idx}, g_rx_last, u32(0))'
								}
							}
							glue << '\t\t\t}'
						}
						glue << rx_target_arms(m)
						glue << trace_rx_arms(m, part)
					glue << shell_rx_arms(m)
					glue << diag_target_rx_arm(m)
					glue << nm_rx_arms(m)
					// an NM frame that woke the network: the next frame sees the new state
					glue << comm_nm_transition(m)
					glue << xcore_trace_rx_arm(m)
						// GATEWAY: forward routes whose SOURCE is the telem bus (`ch`) — raw copy +
						// id remap onto the destination channel (tx_ready-gated).
						glue << gateway_forward_arms(m, m.telem.bus)
						glue << '\t\t}'
						// GATEWAY: drain each OTHER route bus and forward its routes. Same wake
						// semaphore, so one comm_rx_wait covers every bus; recv is non-blocking.
						for b in gw_extra {
							glue << '\t\tfor ch_${snake(b)}.recv(mut rx) { // route bus ${b}'
							glue << gateway_forward_arms(m, b)
							glue << '\t\t}'
						}
						}
						.tick {
							glue << '\t\tt1 := C.board_now_us()'
							// NM drains FIRST: produce() ticks the state machine, so the gate
							// below reflects THIS pass's state — otherwise the producers get one
							// free frame past the sleep boundary (codex on emb#135).
							glue << diag_target_nm_hold(m)
							glue << nm_produce_drain(m)
						}
						.cycle {
							glue << fault_target_cycle(m, 't1', '\t\t')
						}
						.settle {
							glue << rx_target_settle(m)
						}
						.persist {
							// after the pass's last consume, so a DTC persisted now has its snapshot
							glue << fault_capture_lines(m, 'g_fmem', 'g_diag', '\t\t')
							glue << fault_target_persist(m, ioc_idx)
							glue << param_sleep_lines(m, ioc_idx)
						}
					}
					if glue.len == at + 1 {
						glue.delete(at)
					}
				}
				if m.nm.on {
					// REQ-COM-007: every producer below gates on this — the bus is
					// SILENT in sleep; NM's own drain is exempt (its state machine
					// owns its wire behaviour, and the wake announcement must out).
					glue << '\t\tnm_up := g_nm.awake() // NM-gated COM tx (REQ-COM-007, post-tick)'
				}
				glue << diag_target_produce(m) // ahead of every periodic producer: a tester is timing it
				glue << diag_target_reset(m, ioc_idx)
				for p in producers {
					glue << p.bus_tick(BusCtx{
						telem_active: m.telem.on && telem_iface != ''
						lead:         ["\t\t// PRODUCER: CpuLoad telemetry — reads the FB thread's load scratch"]
						now:          't1'
						period:       'telem_period_us'
						gate:         if m.nm.on { ' && nm_up && ch.tx_ready()' } else { ' && ch.tx_ready()' }
						load:         ['\t\t\tmut load := [8]u16{}', comm_load_line]
						ncores:       comm_ncores
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
					nm_gate := if m.nm.on { 'nm_up && ' } else { '' }
					glue << '\t\tif ${nm_gate}${diag_tx_gate(m)}t1 - last_tx_${snake(si.name)} >= u64(${cyc}) && ch.tx_ready() {'
					glue << '\t\t\tlast_tx_${snake(si.name)} = t1'
					glue << '\t\t\tmut tv_a := u32(0)'
					glue << '\t\t\tmut tv_b := u32(0)'
					glue << '\t\t\tmut tf := can.Frame{'
					glue << '\t\t\t\tid:  u32(0x${si.dbc_id.hex()})'
					glue << '\t\t\t\tlen: ${si.dbc_dlc}'
					glue << '\t\t\t}'
					glue << pdu_init_lines(si, 'tf', '\t\t\t')
					glue << '\t\t\tmut tf_sat := u32(0)'
					// until the FB's first publish the cell holds no value, only its zero: the frame
					// goes out at its initial payload, and nothing is encoded or counted
					glue << '\t\t\tif C.ioc_get_ever(${idx}, &tv_a, &tv_b) != 0 {'
					glue << lane_encode_lines(si, 0, si.val_type, 'tv_a', 'tf', 'tf_sat', '\t\t\t\t')
					glue << '\t\t\t}'
					glue << '\t\t\tif ch.send(tf) {'
					glue << '\t\t\t\ttx_sat.add(tf_sat)'
					glue << '\t\t\t}'
					glue << '\t\t}'
				}
				glue << trace_produce_drain(m)
				glue << shell_produce_drain(m)
				glue << xcore_trace_poll(m)
				glue << xcore_produce_drain(m)
				if target_encodes(m) {
					glue << tx_sat_did_lines(m, if m.isotp_conns.len > 0 { ['g_diag.server'] } else { []string{} }, 'tx_sat.count', '\t\t')
				}
				glue << emit_bulk_service_arm(m.bulk, m.part, '', '\t\t') // owner cross-core bulk service (poll)
				glue << nvm_service(m, ioc_idx)
				glue << '\t}'
				glue << '}'
				glue << ''
				glue << "@[export: 'tx_application_define']"
				glue << 'fn tx_application_define(first_unused voidptr) {'
				glue << emit_io_target_boot(m, ioc_idx)
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
				if m.io_points.len > 0 {
					glue << emit_io_target_create(comm_prio + 1)
				}
				glue << emit_eth_target_create(m, comm_prio)
				glue << doip_target_create(m)
				glue << display_target_create(m)
				if m.trace.on {
					// Deterministic trace thread ids (manifest order): comm = 1, then the app
					// threads by priority, then the io thread; the ONLY first-sight id left is
					// the ThreadX timer thread — always last, exactly as the manifest's
					// tx_system_timer row says.
					glue << '\tC.trace_bind_thread(&g_comm_tcb[0])'
					if multi {
						for thr in app_threads {
							glue << '\tC.trace_bind_thread(&g_${thr}_tcb[0])'
						}
					} else {
						glue << '\tC.trace_bind_thread(&g_${part}_tcb[0])'
					}
					if m.io_points.len > 0 {
						glue << '\tC.trace_bind_thread(&g_io_tcb[0])'
					}
					if eth_thread_on(m) {
						glue << '\tC.trace_bind_thread(&g_eth_tcb[0])'
					}
					glue << doip_target_trace_binds(m)
				}
				glue << '}'
			} else {
				// No comm thread: the io thread (when present) runs just above the FB
				// thread(s) — min FB priority - 1 — so its cadence never waits on an app pass.
				if m.io_points.len > 0 && min_prio < 1 {
					panic('loom2v: [target] kind="threadx" with [[io.gpio]]: the io thread runs at ' +
						'min FB priority - 1 = ${min_prio - 1}, out of the ThreadX range 0..31; ' +
						'use FB priorities >= 1')
				}
				if multi {
					// multi-thread node (any bus shape): one entry per app thread,
					// like the comm branch — run() does not exist in the multi cut,
					// and the app threads never touch CAN here (codex on emb#150 r5/r6)
					for thr in app_threads {
						glue << 'fn ${thr}_thread_entry(input u32) {'
						glue << '\trun_${thr}()'
						glue << '}'
						glue << ''
					}
				} else {
					glue << 'fn ${part}_thread_entry(input u32) {'
					if m.buses.len == 0 || eth_only_img(m) {
						// an io-only node (no [bus] at all) or an eth-only node:
						// run() is channel-free — emitting a can.Channel here would
						// reference an import the header emitter correctly skipped
						glue << '\trun()'
					} else {
						glue << '\tmut ch := can.Channel{}'
						glue << "\tif !ch.open('${tx_bus_idx}', ${tx_bus_fd}) { // ${m.telem.bus}; board clocks/pins set by main.v"
						glue << '\t\treturn // CAN open failed (bad bus index / FD unsupported) — don\'t run with a dead channel'
						glue << '\t}'
						glue << '\trun(ch)'
					}
					glue << '}'
				}
				glue << ''
				glue << "@[export: 'tx_application_define']"
				glue << 'fn tx_application_define(first_unused voidptr) {'
				glue << emit_io_target_boot(m, ioc_idx)
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
				if m.io_points.len > 0 {
					glue << emit_io_target_create(min_prio - 1)
				}
				// the eth owner sits ABOVE the io thread (min-2 vs min-1): both are
				// TX_NO_TIME_SLICE, so an equal-priority eth drain pass would run to
				// completion ahead of a due io cadence (codex #169 r2)
				glue << emit_eth_target_create(m, min_prio - 2)
				glue << display_target_create(m)
				if m.trace.on {
					// Deterministic ids in MANIFEST order (app threads, then io) — without
					// explicit binds the io thread, running at min FB - 1, is first-sighted
					// as id 1 and every lane label swaps (codex on emb#150).
					if multi {
						for thr in app_threads {
							glue << '\tC.trace_bind_thread(&g_${thr}_tcb[0])'
						}
					} else {
						glue << '\tC.trace_bind_thread(&g_${part}_tcb[0])'
					}
					if m.io_points.len > 0 {
						glue << '\tC.trace_bind_thread(&g_io_tcb[0])'
					}
					if eth_thread_on(m) {
						glue << '\tC.trace_bind_thread(&g_eth_tcb[0])'
					}
				}
				glue << '}'
			}
			glue << ''
			glue << '// boot: hand control to the ThreadX kernel (never returns; calls'
			glue << '// tx_application_define above). main.v does the board bring-up then calls this —'
			glue << '// referencing it also forces this module (incl. tx_application_define) to link.'
			glue << nvm_flash_wrappers(m)
			glue << fault_store_fns(m)
			glue << param_fns(m, ioc_idx)
			glue << 'pub fn boot() {'
			if has_satellite(m) {
				// release the parked satellite core BEFORE the kernel: it waits on XCORE_CLK_MAGIC
				// (xcore_wait_clocks). main.v has already run board_clock_init, so the satellite's
				// SysTick is set against the final HCLK. Generator-owned so any owner — a shared
				// main.v (system_full) or a hand-written one — releases its satellite (codex #235).
				glue << '\tC.xcore_clocks_ready()'
			}
			if ioc_idx.len > 0 {
				glue << '\tC.ioc_pool_init() // init the cross-thread signal IOC cells before any thread runs'
			}
			glue << nvm_boot_lines(m, ioc_idx)
			glue << param_boot_lines(m)
			if m.eth_frames.len > 0 {
				// byte IOC channels for the eth signals, each arena sized to its
				// SIGNAL's in-memory struct (the ioc.h size-proportional rule) —
				// configured before any thread runs, like ioc_pool_init above
				mut bnames := eth_iocb_idx(m).keys()
				bnames.sort()
				for bn in bnames {
					glue << '\tmut cfg_${snake(bn)} := sig.${bn}{}'
					glue << '\tC.iocb_cfg(${eth_iocb_idx(m)[bn]}, u16(sizeof(cfg_${snake(bn)})))'
				}
			}
			glue << rx_target_boot(m)
			glue << fault_target_boot(m)
			glue << '\tC._tx_initialize_kernel_enter()'
			glue << '}'
		}
	return glue
}

// emit_run_host emits the plain multi-core host run(): launch every bus bridge + app partition,
// then wait. One Channel param per bus (sorted for a stable signature). Reads the Model; telem_iface
// / bus_names / bus_dests / extra_dest_buses are main's emit-time state.
fn emit_run_host(m Model, telem_iface string, bus_names []string, bus_dests map[string][]string, extra_dest_buses []string, tctx TraceHostCtx, doc toml.Doc) []string {
	mut glue := []string{}
	mut has_io_input := false
	for pt in m.io_points {
		if !pt.output {
			has_io_input = true
		}
	}
	if has_io_input {
		// the startup-fault counter is an exported symbol (docs/io.md
		// observability rule): SWD/bench readable even with no service on
		glue << ''
		glue << '// inputs whose initial boot sample could not be read — nothing was published'
		glue << '// for them (no fabricated sample); consumers hold their declared default'
		glue << '__global ('
		glue << '\tio_startup_faults u32'
		glue << ')'
	}
		// --- host run(): launch every bus bridge + app partition, then wait. One
		//     Channel param per bus (sorted for a stable signature main.v can rely
		//     on); the eth bus adds its UDP Socket param LAST (docs/someip.md). ---
		glue << ''
		mut waits := []string{}
		// any eth frame (either direction) needs the comm thread + its socket
		eth_on := m.eth_frames.len > 0
		mut params := []string{}
		for b in bus_names {
			params << '${snake(b)} can.Channel'
		}
		for b in extra_dest_buses {
			params << '${snake(b)} can.Channel' // route-dest-only bus: channel arg, no bridge
		}
		if eth_on {
			params << '${snake(m.eth)}_sock eth.Socket' // the eth comm thread's UDP seam
		}
		if params.len == 0 {
			glue << 'pub fn run() {'
		} else {
			glue << 'pub fn run(${params.join(', ')}) {'
		}
		if m.io_points.len > 0 {
			// io before EVERYTHING (REQ-IO-009): declare + init the points — outputs
			// hold their configured init from here — then publish ONE initial sample
			// per input so the first app activation never reads an empty channel
			// (docs/io.md startup ordering: platform first, app after). An input the
			// backend cannot READ at boot publishes nothing (a fabricated sample is
			// worse than none) and bumps the exported startup-fault counter; the io
			// thread's periodic reads then use last-good semantics as usual.
			for pt in m.io_points {
				hal := if pt.active_low { 1 } else { 0 }
				hkind := if pt.kind == 'adc' { 1 } else if pt.kind == 'pwm' { 2 } else { 0 }
				hiv := if pt.kind == 'pwm' { pt.init_pm } else if pt.init { u32(1) } else { u32(0) }
				glue << "\tif !io.cfg(${pt.ch}, '${pt.name}', '${pt.pin}', ${pt.output}, ${hiv}, ${hal}, ${hkind}, ${io_cfg_param(pt, m)}) {"
				glue << "\t\tpanic('io cfg failed: ${pt.name}')"
				glue << '\t}'
			}
			glue << '\tif !io.init() {'
			glue << "\t\tpanic('io init failed')"
			glue << '\t}'
			for pt in m.io_points {
				if pt.output {
					continue
				}
				si := m.sig_of[pt.name] or { continue }
				fld := snake(pt.name)
				if pt.kind == 'adc' {
					glue << '\tif boot_${fld}_v := io.adc_read_checked(${pt.ch}) {'
					glue << '\t\tmut boot_${fld} := sig.${pt.name}{ ${si.val_field}: ${adc_cast(si.val_type)}(boot_${fld}_v) }'
					glue << '\t\tosal.${publish_fn(si.transport)}(${fld}_ch, &boot_${fld}, u8(sizeof(boot_${fld})))'
					glue << '\t} else {'
					glue << '\t\tio_startup_faults++ // no first sample: publish NOTHING (the port'
					glue << '\t\t// default holds; a published default would be a fabricated fresh sample)'
					glue << '\t}'
				} else {
					glue << '\tif boot_${fld}_v := io.gpio_read_checked(${pt.ch}) {'
					glue << '\t\tmut boot_${fld} := sig.${pt.name}{ ${si.val_field}: boot_${fld}_v }'
					glue << '\t\tosal.${publish_fn(si.transport)}(${fld}_ch, &boot_${fld}, u8(sizeof(boot_${fld})))'
					glue << '\t} else {'
					glue << '\t\tio_startup_faults++ // unreadable at boot: publish NOTHING'
					glue << '\t}'
				}
			}
			if has_io_input {
				// host diagnostics only — the exported counter stays the bench contract
				glue << '\tif io_startup_faults > 0 {'
				glue << "\t\teprintln('io: startup fault(s) — count in io_startup_faults') // no interpolation: -gc none"
				glue << '\t}'
			}
			glue << '\tt_io := spawn partition_io()'
			waits << 't_io'
		}
		if tctx.on() {
			// P3b: ONE capture origin for both lanes (a per-thread origin skews them by the
			// thread-start delay, invisibly — a shared clock emits no core-offset record), the
			// satellite's ring, and the freeze cell they share.
			glue << trace_run_setup(m, tctx.sat, doc)
		}
		for b in bus_names {
			bb := snake(b)
			if tctx.on() && b == tctx.trace_bus {
				continue // a channel parameter only: the bridge owner drains this bus
			}
			mut spawn_args := bb
			for d in bus_dests[b] or { []string{} } {
				spawn_args += ', ${snake(d)}'
			}
			if tctx.on() && b == tctx.owner_bus {
				spawn_args += trace_bridge_spawn_args(tctx.trace_bus)
			}
			glue << '\tt_${bb} := spawn partition_${bb}(${spawn_args})'
			waits << 't_${bb}'
		}
		for part, _ in m.part.by_part {
			arg := if tctx.on() && part == tctx.sat {
				'unsafe { voidptr(&sat_cap) }' // the satellite's capture: its ring is the owner's to dump
			} else {
				'unsafe { nil }'
			}
			glue << '\tt_${part} := spawn partition_${part}(${m.part.core_of[part] or { 0 }}, ${arg})'
			waits << 't_${part}'
		}
		// ...but not in the bridge-owner shape: the owner sends CpuLoad from its own loop, so
		// no telemetry thread exists to spawn (and none preempts its traced drain spans).
		if telem_on_can(m) && telem_iface != '' && !tctx.on() {
			glue << '\tt_telem := spawn partition_telem()'
			waits << 't_telem'
		}
		if eth_on {
			eb := snake(m.eth)
			glue << '\tt_${eb} := spawn partition_${eb}(${eb}_sock)'
			waits << 't_${eb}'
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
//
// image_part selects the pass: '' emits the OWNER image (every non-external partition);
// a partition name emits ONLY that satellite partition (the multi-image pass, gen_image.v)
// — same structs/wrappers, with remote writes going to xcore_pub instead of an IOC cell.
fn emit_handlers(m Model, producers []Producer, ioc_idx map[string]int, trace_owns_run bool, image_part string, tctx TraceHostCtx) ([]string, []string, map[string][]string) {
	mut ports := []string{}
	mut glue := []string{}
	mut all_regs := map[string][]string{}
	for part, clist in m.part.by_part {
		if image_part == '' && m.part.external[part] {
			continue // declared elsewhere: identity only, no generated code
		}
		if image_part != '' && part != image_part {
			continue // the satellite pass emits exactly one partition
		}
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
				nf := m.faults.filter(it.fb == cname).len
				if nf > 0 {
					if multi {
						panic('loom2v: fb "${cname}" owns [[fault]]s in a multi-thread partition — not generated yet; put it in a single-thread partition')
					}
					glue << '\tfdeb_${snake(cname)} [${nf}]fault.Debounce // its faults, debounced on this thread'
					glue << '\tfctl_${snake(cname)} fault.Control // generations to apply (and held flags), from the diagnostic bridge'
					glue << '\tfrep_${snake(cname)} fault.Reports // debounced state + counters, to the bridge'
				}
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
					if p := param_of(m, r.string()) {
						ports << '\t// parameter "${p.name}" — coded with 0x2E on DID 0x${p.did.hex()}, read-only'
						ports << '\t${snake(p.name)} sig.${p.name}'
						continue
					}
					ports << provenance(r.string(), m.sig_of)
					// an input point's declared default becomes the port field's
					// initial value — the FB sees it until the first real sample
					// (docs/io.md); the acquire leaves the field untouched on no-data
					mut dflt := ''
					for pt in m.io_points {
						if pt.name == r.string() && !pt.output && pt.has_default {
							si_r := m.sig_of[r.string()] or { SigInfo{} }
							// gpio default is bool; adc default is the numeric count (codex emb#152)
							dval := if pt.kind == 'adc' { '${pt.default_u32}' } else { '${pt.default}' }
							dflt = ' = sig.${r.string()}{ ${si_r.val_field}: ${dval} }'
						}
					}
					ports << '\t${snake(r.string())} sig.${r.string()}${dflt}'
				}
				ports << '}'
				hfaults := m.faults.filter(it.fb == cname && it.handler == hname)
				if hfaults.len > 0 {
					ports << 'pub struct ${cname}Faults {'
					ports << 'pub mut:'
					for f in hfaults {
						ports << '\t${snake(f.name)} fault.TestResult // DTC 0x${f.dtc.hex()}: write the CURRENT result each dispatch, no latch (docs/diagnostics.md §3.3)'
					}
					ports << '}'
				}
				ports << 'pub struct ${cname}Out {'
				ports << 'pub mut:'
				for w in writes {
					ports << provenance(w.string(), m.sig_of)
					ports << '\t${snake(w.string())} sig.${w.string()}'
				}
				if hfaults.len > 0 {
					ports << '\tfault ${cname}Faults'
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
					if p := param_of(m, rn) {
						glue << param_read_lines(p, ioc_idx[rn] or {
							panic('loom2v: parameter "${rn}" has no IOC cell on this image')
						})
						continue
					}
					if si.local {
						glue << '\tinp.${snake(rn)} = st.cell_${snake(rn)} // local'
					} else if idx := ioc_idx[rn] {
						// bus -> comm(decode) -> target IOC cell ${idx} -> this FB input (6b-2b). One
						// ioc_get per read (it advances the reader slot); the value field is `a`.
						glue << '\tmut ${snake(rn)}_a := u32(0)'
						glue << '\tmut ${snake(rn)}_b := u32(0)'
						mut io_input := false
						for pt in m.io_points {
							if pt.name == rn && !pt.output {
								io_input = true
							}
						}
						// V has no u32 -> bool cast; io gpio signals are bool by shape rule
						asn := if si.val_type == 'bool' {
							'inp.${snake(rn)}.${snake(si.val_field)} = ${snake(rn)}_a != 0'
						} else {
							'inp.${snake(rn)}.${snake(si.val_field)} = ${si.val_type}(${snake(rn)}_a)'
						}
						if io_input {
							// io input: gate on ever-published (the io outputs' ioc_get_ever gate) —
							// after a failed boot read the cell is a zero slot, not a sample; the
							// port's declared default must hold until a REAL publish
							glue << '\tif C.ioc_get_ever(${idx}, &${snake(rn)}_a, &${snake(rn)}_b) != 0 {'
							glue << '\t\t${asn}'
							glue << '\t}'
						} else {
							glue << '\tC.ioc_get(${idx}, &${snake(rn)}_a, &${snake(rn)}_b)'
							glue << '\t${asn}'
						}
					} else if bidx := rx_iocb_idx(m)[rn] {
						// a received signal crossing whole on the ThreadX target: the eth thread's
						// unpacked struct (docs/someip.md), or a checked CAN frame's decoded signal
						// with its status (gen_rx_target.v)
						glue << '\tC.iocb_get(${bidx}, &inp.${snake(rn)})'
					} else if rn in m.xcore_names && image_part == '' && m.target.threadx {
						// OWNER FB reads a CROSS-CORE signal (satellite -> owner) on the TARGET: read it
						// through the same xioc seam the comm thread uses for tx (target_ext.c's xcore_poll
						// holds static per-slot state, so a/b carry the last-good value — latest-value
						// semantics: a satellite that stops publishing keeps its last value). Gate on the
						// layout handshake: until the satellite acks a MATCHED build, keep the port default
						// rather than trust another build's slot bytes (same gate as the comm tx). Scalar
						// (<=2 field) only — a wide cross-core FB read needs FB-held reader state (rung 2c).
						if si.wide {
							panic('loom2v: owner fb "${cname}" reads WIDE cross-core signal "${rn}" — not ' +
								'wired (scalar xioc only); make it a scalar signal or transmit it on a bus')
						}
						glue << '\tif C.xcore_layout_ok() != 0 { // trust cross-core slots only once the satellite acks a matched build'
						glue << '\t\tmut ${snake(rn)}_a := u32(0)'
						glue << '\t\tmut ${snake(rn)}_b := u32(0)'
						glue << '\t\tC.xcore_poll(${m.xcore_idx[rn] or { 0 }}, &${snake(rn)}_a, &${snake(rn)}_b) // xioc reader; target_ext.c holds last-good'
						for fi, f in si.fields {
							if fi > 1 {
								break
							}
							src := if fi == 0 { '${snake(rn)}_a' } else { '${snake(rn)}_b' }
							if f.typ == 'bool' {
								glue << '\t\tinp.${snake(rn)}.${snake(f.name)} = ${src} != 0'
							} else {
								glue << '\t\tinp.${snake(rn)}.${snake(f.name)} = ${f.typ}(${src})'
							}
						}
						glue << '\t}'
					} else {
						if image_part != '' {
							panic('loom2v: satellite partition "${part}" fb "${cname}" reads signal ' +
								'"${rn}", which is not thread-local — an owner->satellite transport is ' +
								'not generated yet (docs/multi-image.md)')
						}
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
						if si.persist != '' && image_part == '' && wn in ioc_idx {
							// persistent: stage the new value for the comm thread's
							// journal service (wait-free ioc cell, single writer)
							f0 := 'u32(outp.${snake(wn)}.${snake(si.fields[0].name)})'
							f1 := if si.fields.len > 1 {
								'u32(outp.${snake(wn)}.${snake(si.fields[1].name)})'
							} else {
								'u32(0)'
							}
							glue << '\tC.ioc_pub(${ioc_idx[wn]}, ${f0}, ${f1}) // persist staging'
						}
					} else if xoff := m.xcore_xw_off[wn] {
						// wide remote signal (xioc_n): one u32 lane per field, lane order =
						// field order = wire order — packed into the signal's channel in the
						// board wide window (xcore_gen.h XCORE_XW_*_OFF; boot init'd this side).
						glue << '\tmut xw_${snake(wn)} := [${si.fields.len}]u32{}'
						for fi, f in si.fields {
							if f.typ == 'bool' {
								glue << '\txw_${snake(wn)}[${fi}] = if outp.${snake(wn)}.${snake(f.name)} { u32(1) } else { u32(0) }'
							} else {
								glue << '\txw_${snake(wn)}[${fi}] = u32(outp.${snake(wn)}.${snake(f.name)})'
							}
						}
						glue << '\tC.xcore_pub_n(u32(${xoff}), &xw_${snake(wn)}[0])'
					} else if dslot := m.xcore_idx[wn] {
						// remote (cross-image) signal: publish the {a, b} pair into its xioc slot —
						// the bus owner polls it (xcore_produce_drain / platform C). Field order = wire
						// order (validated against the DBC in the comm-thread walk).
						b_expr := if si.fields.len > 1 {
							'u32(outp.${snake(wn)}.${snake(si.fields[1].name)})'
						} else {
							'u32(0)'
						}
						glue << '\tC.xcore_pub(${dslot}, u32(outp.${snake(wn)}.${snake(si.fields[0].name)}), ${b_expr})'
					} else if idx := ioc_idx[wn] {
						// external TX (app -> bus) or io output (app -> pin): publish the value into its
						// IOC cell; the consumer (comm thread / io thread) reads it each period. Value
						// field -> sig_t.a (b unused). bool has no u32() cast in V — branch the literal.
						wexpr := if si.val_type == 'bool' {
							'if outp.${snake(wn)}.${snake(si.val_field)} { u32(1) } else { u32(0) }'
						} else {
							'u32(outp.${snake(wn)}.${snake(si.val_field)})'
						}
						glue << '\tC.ioc_pub(${idx}, ${wexpr}, u32(0))'
					} else if bidx := eth_iocb_idx(m)[wn] {
						// eth tx signal on the ThreadX target: publish the struct into
						// its byte IOC channel; the eth thread packs it onto the wire
						glue << '\tC.iocb_pub(${bidx}, &outp.${snake(wn)})'
					} else {
						if image_part != '' {
							panic('loom2v: satellite partition "${part}" fb "${cname}" writes signal ' +
								'"${wn}", which is neither thread-local nor a remote xioc signal — a ' +
								'satellite image has no other transport (docs/multi-image.md)')
						}
						glue << '\tosal.${publish_fn(si.transport)}(${snake(wn)}_ch, &outp.${snake(wn)}, u8(sizeof(outp.${snake(wn)})))'
					}
				}
				// the fault report AFTER the outputs: a snapshot the owner takes on reading it then
				// sees this dispatch's outputs, not the previous one's (a fault may freeze a DID its
				// own handler writes — zone_a's SteerLimiter and SteeringAngle)
				glue << fault_step_lines(m, cname, hname)
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
		if !m.target.on && (!trace_owns_run || tctx.on()) {
			glue << ''
			glue << 'pub fn partition_${part}(core int, arg voidptr) {'
			glue << '\tosal.pin_to_core(${m.part.core_of[part] or { 0 }})'
			glue << '\tmut st := Partition_${part}_state{}'
			for c in clist {
				glue << fault_init_lines(m, (c.as_map()['name'] or { toml.Any('') }).string())
			}
			glue << '\tmut sched := loom.Scheduler{}'
			for r in regs {
				glue << r
			}
			traced_sat := tctx.on() && part == tctx.sat
			if traced_sat {
				// P3b satellite: run() passes its Capture through the `arg` this signature
				// already carries, so the ring lives with the owner that dumps it.
				glue << trace_sat_preamble()
			}
			for p in producers {
				glue << p.partition_preamble('p:${part}')
			}
			glue << '\tfor {'
			for p in producers {
				glue << p.partition_loop_top('p:${part}')
			}
			mut disp := if traced_sat {
				trace_profiled_dispatch(false) // the hook fires per handler; run_profiled accounts the pass
			} else {
				[
					'\t\tloom_t0 := osal.now_us()',
					'\t\tsched.run(loom_t0)',
					'\t\tloom_t1 := osal.now_us()',
					'\t\tsched.account(loom_t1 - loom_t0, loom_t1) // per-core load',
				]
			}
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
fn emit_module_headers(m Model, ecu string, comm_thread_on bool, trace_owns_run bool) ([]string, []string) {
	// m.frames is CAN-only (parse_frames skips eth frames — their E2E is the
	// derived trailer, not the comm.e2e path), so these counts stay CAN-true
	has_e2e := m.frames.e2e_on.len > 0
	has_secoc := m.frames.secoc_on.len > 0
	mut ports := []string{}
	ports << '// Code generated by tools/loom2v from ${os.file_name(ecu)} — DO NOT EDIT.'
	ports << 'module ports'
	ports << ''
	// Port structs carry sig.* fields only when there are signals; a pure-compute app (e.g. a
	// trace demo) has none, so skip the import rather than emit an unused-import warning.
	if m.sig_names.len > 0 || m.params.len > 0 {
		ports << 'import sig'
	}
	if m.faults.any(it.signal == '') {
		ports << 'import comm.fault' // the fault port's TestResult (signal-status faults have no port)
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
	if !m.target.on && m.io_points.filter(!it.output).len > 0 {
		// io_startup_faults: the host build has no -enable-globals flag
		glue << '@[has_globals]'
	}
	glue << 'module gen'
	glue << ''
	if has_local || m.has_external || m.io_points.len > 0 {
		glue << 'import sig' // local-cell, bus-bridge and/or io-thread signal structs
	}
	glue << 'import ports'
	glue << 'import app'
	glue << 'import loom'
	if !m.target.on {
		glue << 'import osal' // host: IOC + now_us/sleep_us. Target has none of these.
	}
	if m.io_points.len > 0 {
		glue << 'import driver.io' // the io port — the platform io thread owns every pin touch
	}
	// telem.* is used for CpuLoad (telemetry) — import it only when it's actually emitted.
	if telem_on_can(m) {
		glue << 'import comm.telem' // CpuLoad packing
	}
	if trace_owns_run || (m.trace.on && m.target.threadx) {
		glue << 'import comm.trace' // the TraceModule + ring + hooks (docs/com-modules.md)
	}
	if m.shell.on && m.target.threadx {
		glue << 'import comm.shell' // the CAN shell module (docs/com-modules.md)
	}
	if m.nm.on && m.target.threadx {
		glue << 'import comm.nm' // the NM state machine (Timings)
		glue << 'import comm.nm_can' // NM-over-CAN as a ComModule (docs/com-modules.md)
	}
	if nvm_on(m) && m.target.threadx {
		glue << 'import nvm' // the persistence journal (docs/nvm.md)
		glue << 'import boot as bootfl' // FlashOps — aliased: gen has its own boot()
	}
	// ...and a MODULE-HOST bridge, which is can.Channel/can.Frame with none of the above: a
	// multi-partition host with [trace] on a CAN bus and telemetry off has no external signals,
	// no ISO-TP and no routes, so the import predicate missed it and the generated file did not
	// compile. (Both examples happen to have telemetry on, which is why nothing caught it.)
	mut module_host_bus := false
	for bname, _ in m.buses {
		if (m.bus_kind[bname] or { 'can' }) == 'can' && bus_hosts_modules(m, bname, trace_owns_run) {
			module_host_bus = true
		}
	}
	if m.has_can_ext || m.isotp_conns.len > 0 || telem_on_can(m) || m.routes.len > 0
		|| module_host_bus {
		glue << 'import driver.can' // the generated bus bridge (+ gateway routes)
	}
	// eth: only a TX frame emits a pack fn referencing com.max_pdu — an
	// rx-only image gets consts alone, and V rejects an unused import
	mut has_eth_tx := false
	for fr in m.eth_frames {
		if fr.tx {
			has_eth_tx = true
		}
	}
	if (m.has_can_ext && !comm_thread_on) || has_eth_tx || m.routes.any(it.signal != '')
		|| (comm_thread_on && (rx_target_on(m) || target_encodes(m))) {
		glue << 'import comm.com' // per-PDU TX modes + RX deadline; eth codec PDU bound (max_pdu); signal-route producer TxState
	}
	// the eth comm thread's codec: pure V, both sides of the silicon line; the
	// driver.eth module (whose #flag compiles the POSIX backend) is host-only —
	// the target reaches the NetX seam through raw FFI (eth_netx.c)
	if (m.eth_frames.len > 0 && !m.target.on) || eth_thread_on(m) {
		glue << 'import comm.someip' // the SOME/IP header codec
	}
	if m.eth_frames.len > 0 && !m.target.on {
		glue << 'import driver.eth' // the eth UDP seam (docs/someip.md)
	}
	mut eth_e2e := false
	for fr in m.eth_frames {
		// either direction: tx stamps the trailer, rx checks it
		if fr.e2e_on {
			eth_e2e = true
		}
	}
	if has_e2e || eth_e2e {
		glue << 'import comm.e2e' // end-to-end protection (CRC + alive counter)
	}
	if has_secoc {
		glue << 'import comm.secoc' // SecOC authentication (AES-CMAC + freshness)
	}
	if m.faults.len > 0 {
		glue << 'import comm.fault' // debounce + the fault memory (docs/diagnostics.md §3.3)
	}
	if m.params.len > 0 {
		glue << 'import comm.param' // the parameters (docs/diagnostics.md §3.4)
	}
	if m.doip.on {
		glue << 'import comm.doip' // the diagnostic server over DoIP too (gen_doip.v)
		glue << 'import driver.doipnet' // its network loop, shared with the node's bootloader
	}
	if m.isotp_conns.len > 0 {
		glue << 'import comm.diag' // the diagnostic server on its ISO-TP connection
		// the glue names uds only for [[did]]s — their tables, the live refresh, 0x27 — and for a
		// [uds] service table
		// a [uds] service table, and the programming handoff (uds.reset_into_boot)
		if m.dids.len > 0 || m.uds.table || m.boot.on {
			glue << 'import comm.uds' // UDS diagnostic services
		}
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
	mut m := build_model(doc, dbc)
	m.nvm_names, m.nvm_ids = derive_nvm(mut m, doc)
	m.fault_status_id, m.fault_snap_ids, m.fault_snap_ids_b = derive_fault_nvm(m)
	validate_params(mut m, doc)
	derive_param_nvm(mut m)
	check_journal_capacity(m)
	m.fault_grace_us = fault_grace_us(m, doc)
	wear_report := check_journal_wear(m, doc)
	validate_doip(m)
	validate_net(m)
	display_check(m)

	// [trace]: ThreadX streams the exec hooks (gen_trace.v); every other shape serves comm/trace's
	// TraceModule from the loop that owns the bus — a host runner, or the bare-metal superloop
	// itself (P3c-0). A shape none of them covers fails generation (trace_shape_blocker).
	// trace_host: the single-core host module runner (one partition, no COM bridge) — ONE loop
	// owns the schedule and the bus, serving comm/trace's TraceModule via the endpoint bindings.
	// eth signals create no CAN bridge, so only CAN externals conflict with
	// the trace-host runner owning the bus — and the trace bus itself must be
	// CAN (an eth trace binding is validator-rejected until the UDP rung, but
	// this predicate must never route it into the can.Channel runner)
	trace_bus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
	// DERIVED from the one shape policy (ecumodel.trace_shape_blocker, shared with sysmodel) so the
	// predicate and the failure message can never drift apart — a condition added there reaches
	// both. Two host trace runners sit behind it: ONE partition (the original single-core shape)
	// and TWO (P3a — one dump owner plus one satellite core). Both own the schedule AND the bus in
	// an app partition, so neither coexists with a COM bridge; two is today's ceiling because
	// TraceModule holds exactly one satellite import slot (set_remote).
	trace_owns_run := m.trace.on && trace_shape_blocker(m, trace_bus) == ''
	trace_nparts := m.part.by_part.keys().len
	// P3b: with a COM bridge, the OWNER is the bridge partition, not an app partition — the plain
	// host run() still drives everything and the trace machinery rides the bridge's loop
	// (TraceHostCtx). Without one, the app-partition runners own the run() outright: one
	// partition (single-core) or two (P3a, owner + satellite).
	trace_owner_b := trace_owner_bus(m, trace_bus)
	mut tctx := TraceHostCtx{}
	if trace_owns_run && trace_owner_b != '' {
		sat := m.part.by_part.keys()[0]
		tctx = TraceHostCtx{
			owner_bus: trace_owner_b
			trace_bus: trace_bus
			sat:       sat
			sat_core:  m.part.core_of[sat] or { 0 }
		}
	}
	if tctx.on() {
		validate_trace_bridge_owner(m, tctx)
	}
	// The host runners replace run(); a target keeps its own run() and the bare-metal superloop
	// wires the module into it (P3c-0, baremetal_trace_*), so neither host runner applies there.
	trace_host := trace_owns_run && trace_nparts == 1 && !tctx.on() && !m.target.on
	trace_multicore := trace_owns_run && trace_nparts == 2 && !tctx.on() && !m.target.on
	// the trace-host runner has no eth spawn wiring — an eth tx frame there
	// would generate a comm thread nothing starts (silently dead)
	if trace_owns_run && m.eth_frames.len > 0 {
		panic('loom2v: eth frames + the trace-host runner are not wired yet — the eth comm thread is spawned by the plain host run() only (docs/someip.md)')
	}
	// io emits the platform io thread for the plain host run() (P1) and the ThreadX
	// target (the bench phase). The bare-metal superloop / trace-host runner still
	// spawn no io thread — there the pins would silently never move, so fail loudly.
	if m.io_points.len > 0 && ((m.target.on && !m.target.threadx) || trace_owns_run) {
		// The bridge-owner shape keeps the plain host run(), io thread included — but the io
		// thread is neither TRACED (it gets no capture or ring, so `thread+fb` would silently
		// omit every io service) nor EXCLUDED from the traced lanes' wall time (run_profiled
		// charges its preemption to whichever lane it interrupts, which can trip budget_us and
		// freeze both rings for work they did not do). Giving it a lane is #263's shape, and
		// exempting it here would ship exactly the silent degradation this runner exists to
		// remove (codex #274 r3).
		panic('loom2v: [[io.gpio]] is generated for the plain host run() and the ThreadX ' +
			'target only — not the bare-metal superloop, nor a host trace runner: the io thread ' +
			'would be an untraced lane whose preemption is charged to the traced ones (docs/io.md)')
	}
	if m.shell.on && !(m.target.threadx) {
		eprintln('loom2v: WARNING: [shell] is generated for the ThreadX comm-thread target only ' +
			'(the module lives on the bus owner). Building WITHOUT the shell.')
		m.shell.on = false
	}
	if m.nm.on && !(m.target.threadx) {
		eprintln('loom2v: WARNING: [nm] is generated for the ThreadX comm-thread target only ' +
			'(the module lives on the bus owner). Building WITHOUT NM.')
		m.nm.on = false
	}
	if m.xcore_names.len > 0 && !(m.target.threadx) {
		eprintln('loom2v: WARNING: cross-core (remote) signals need the ThreadX comm-thread ' +
			'target (the bus owner transmits them). Building WITHOUT the xioc slots.')
		m.xcore_idx.clear()
		m.xcore_names.clear()
		m.xcore_xw_off.clear()
		m.xcore_xw_total = 0
	}
	if m.trace.on && m.target.threadx {
		validate_trace_threadx(m)
	} else if m.trace.on && !trace_owns_run {
		// Not a warning: a config that asks for trace and silently gets none looks identical to a
		// working one until nothing answers on the bus (#191). Name the one condition that tripped.
		panic('loom2v: [trace] is not generated for this ECU — ${trace_shape_blocker(m, trace_bus)} ' +
			'(docs/com-modules.md). Set [trace] enabled = false to build without it deliberately.')
	}

	// [[signal]] -> the model, then emit the `sig` module.
	mut signals := emit_signals(m.sig_of, m.sig_names, ecu)
	signals << param_sig_structs(m)

	// Per-PDU COM behaviour ([[frame]]), rebound to the existing locals.
	// m.frames is CAN-only — parse_frames skips eth frames, whose E2E trailer
	// is derived + ecumodel-gated, never the DBC-backed machinery below.
	has_e2e := m.frames.e2e_on.len > 0
	has_secoc := m.frames.secoc_on.len > 0

	has_routes := m.routes.len > 0

	// A connection's ids are matched in the owner's rx loop, and sent on, next to everything else on
	// its bus: an application or module frame with the same id would ALSO be dispatched as a
	// diagnostic request (a cyclic frame whose first byte looks like a single-frame PCI could switch
	// sessions), or two producers would transmit one id. Refuse the collision here — standalone
	// images get no syscheck.
	for c in m.isotp_conns {
		// only what is handled on THIS bus can collide (CAN ids are bus-local): the DBC messages
		// its signals ride, the frames routed onto or off it, and the module frames that use it
		mut on_bus := map[string]bool{}
		for _, si in m.sig_of {
			if si.external && si.bus == c.bus && si.dbc_msg != '' {
				on_bus[si.dbc_msg] = true
			}
		}
		db := candb.load_dbc_file(dbc) or { candb.Database{} }
		fn_trace_bus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
		shell_bus := if m.shell.bus != '' { m.shell.bus } else { m.telem.bus }
		// on a ThreadX owner NM runs on the comm thread's channel whatever [nm].bus says (a manifest
		// label there, gateway_test.v)
		nm_bus := if m.target.threadx || m.nm.bus == '' { m.telem.bus } else { m.nm.bus }
		mut ids := [][]string{} // [field, id]
		ids << ['rx_id', c.rx_id.str()]
		ids << ['tx_id', c.tx_id.str()]
		if c.functional_id != 0 {
			ids << ['functional_id', c.functional_id.str()]
		}
		for e in ids {
			field := e[0]
			id := u32(e[1].int())
			what := 'loom2v: [isotp] ${field} 0x${id.hex()} is also'
			for msg in db.messages {
				if on_bus[snake(msg.name)] && u32(msg.id) == id && !msg.ext {
					panic('${what} DBC message "${msg.name}" on bus "${c.bus}"')
				}
			}
			for r in m.routes {
				// the diagnostic ids are STANDARD frames: only a standard-width route can collide
				if (r.from_bus == c.bus && !r.from_ext && u32(r.from_id) == id)
					|| (r.to_bus == c.bus && !r.to_ext && u32(r.to_id) == id) {
					panic('${what} a routed frame on bus "${c.bus}"')
				}
			}
			if m.telem.on && m.telem.bus == c.bus && (id == m.telem.id || (m.telem.detail_id != 0 && id == m.telem.detail_id)) {
				panic('${what} a [telemetry] frame id on bus "${c.bus}"')
			}
			if m.trace.on && fn_trace_bus == c.bus && (id == m.trace.cmd_id || id == m.trace.rsp_id
				|| id == m.trace.record_id || (m.trace.dump_fc_bound && id == m.trace.dump_fc_id)) {
				panic('${what} a [trace] endpoint id on bus "${c.bus}"')
			}
			if m.nm.on && nm_bus == c.bus && ((id >= m.nm.peers_lo && id <= m.nm.peers_hi) || id == m.nm.alive_id) {
				panic('${what} in the [nm] peer range / alive id on bus "${c.bus}"')
			}
			if m.shell.on && !shell_on_eth(m) && shell_bus == c.bus
				&& (id == m.shell.in_id || id == m.shell.fc_id || id == m.shell.out_id) {
				panic('${what} a [shell] endpoint id on bus "${c.bus}"')
			}
		}
	}

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
			// COMPOSED frame (E2E + SecOC, REQ-E2E-004): the four protection fields
			// must occupy disjoint bytes — the E2E CRC excludes the SecOC windows, so
			// a CRC or counter sitting INSIDE them would be stamped over by SecOC and
			// unverifiable; reject the layout rather than compose garbage.
			if m.frames.e2e_on[fk] or { false } {
				cp := m.frames.e2e_crc[fk] or { 0 }
				np := m.frames.e2e_ctr[fk] or { 0 }
				for pos in [cp, np] {
					if pos == fp || (pos >= mp && pos < mp + ml) {
						panic('e2e+secoc ${fk}: crc_pos=${cp}/counter_pos=${np} collide with ' +
							'fresh_pos=${fp}/mac@${mp}+${ml} — REQ-E2E-004 requires disjoint ' +
							'protection bytes (E2E covers the payload, never the SecOC fields)')
					}
				}
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
	// examples/h755_threadx).
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
		io_only_busless := m.io_points.len > 0 && m.buses.len == 0
		if io_only_busless && m.telem.on {
			// telemetry ENABLED but there is no bus to ship it on — the frames would
			// silently never emit (codex on emb#150 r6). The exception below is only
			// for telemetry-OFF io-only nodes; an enabled one must declare its bus.
			panic('loom2v: [target] kind="threadx": [[io.gpio]]-only node with no [bus] cannot ' +
				'enable [telemetry] — there is nothing to transmit CpuLoad on (drop telemetry or add a bus)')
		}
		if (!m.telem.on || m.telem.bus == '') && !io_only_busless && !eth_only_img(m) {
			// exceptions: a telemetry-OFF io-only node (docs/io.md: an output-only
			// ECU) and an eth-ONLY node (docs/someip.md target rung: the eth comm
			// thread owns its socket, no CAN channel exists) — both app entries are
			// emitted channel-free, so nothing here needs the CAN channel
			panic('loom2v: [target] kind="threadx" needs [telemetry] enabled with a bus — the app ' +
				'thread opens it for the CAN channel (exceptions: a telemetry-off [[io.gpio]]-only ' +
				'node, an eth-only node)')
		}
		if !bus_exists && !io_only_busless && !eth_only_img(m) {
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
	// eth-endpoint signals ride the eth comm thread (their own bus owner,
	// docs/someip.md target rung) — they must not conjure the CAN comm thread
	mut has_can_sig := false
	for sn in m.sig_names {
		s := m.sig_of[sn] or { continue }
		if s.external && s.bus != m.eth {
			has_can_sig = true
		}
	}
	has_bridge := has_can_sig || m.isotp_conns.len > 0 || has_routes
	// ThreadX COM bridge (phase 6b-2): the target grows a bus-owning comm thread that services
	// rx (woken by the FDCAN Rx ISR) while the FB thread stays off CAN and publishes load via a
	// scratch cell. The comm thread is the generic bus owner — telemetry and the trace ring are
	// its first two producers, rx frames go to consumers — so NM/COM-tx slot in later as more of
	// the same. The lean first cut supports external RX signals (bus -> app), drained + counted
	// by the comm thread; external TX signals, ISO-TP, and m.routes are not generated yet.
	comm_thread_on := m.target.threadx && has_bridge
	// The ThreadX half of this PR's rule. trace_module_init and trace_produce_drain are emitted
	// INSIDE the `if comm_thread_on` branch, so a ThreadX ECU with [trace] on but no bridge (only
	// partition-local signals, no ISO-TP, no routes) generates no trace machinery at all: nothing
	// serves the commands, nothing transmits records, and the manifest still advertises the ids.
	// That is exactly the silent degradation the host shapes now reject, so reject it here too —
	// the ThreadX branch above validates OPTIONS, and would otherwise pass this straight through.
	if m.trace.on && m.target.threadx && !comm_thread_on {
		panic('loom2v: [trace] on a ThreadX ECU is served by the bus-owning comm thread, which is ' +
			'generated only for an ECU with a COM bridge (an external CAN signal, an ISO-TP ' +
			'connection, or a route). This ECU has none, so no thread would answer a TraceCmd or ' +
			'transmit a record. Give it a bridge, or set [trace] enabled = false.')
	}
	// trace level="all" + io points: run_profiled_excl subtracts the io thread's exec counter
	// per handler, so the profiled load no longer double-counts io preemption (the emb#150 r11
	// refusal). The io thread's OWN work is still not profiled per point (emb#263).
	// the sole LOCAL partition (a satellite image = ... partition is external and
	// makes single_part empty — the guard must count the local one, matching
	// emit_run_target; codex on emb#150 r8)
	mut local_part := ''
	mut n_local := 0
	for pn, _ in m.part.core_of {
		if !m.part.external[pn] {
			local_part = pn
			n_local++
		}
	}
	multi_here := n_local == 1 && (m.part.threads_of[local_part] or { [] }).len > 1
	if m.target.threadx && multi_here && m.telem.on && !comm_thread_on {
		// a multi-thread node with telemetry but NO comm thread (no external
		// signal/route/isotp bridge) has no bus owner: each app thread is
		// FB-dispatch-only, so the CpuLoad frames would silently never emit
		// (codex on emb#150 r7). Single-thread handles it inline in run(); multi
		// needs a real owner — add a bridge signal or drop telemetry.
		panic('loom2v: [target] kind="threadx": a multi-thread node with [telemetry] but no ' +
			'bus bridge (external signal / route / isotp) has no thread to transmit CpuLoad — ' +
			'give it a bus-bound signal or disable telemetry')
	}
	if m.nvm_names.len > 0 && m.target.threadx && !comm_thread_on {
		panic('loom2v: persistent signals need the comm thread (the journal service runs ' +
			'there) — this config has no bus bridge; give the node a bus or drop persist')
	}
	owner_bulk_produces, owner_bulk_consumes := bulk_image_role(m.bulk, m.part, '')
	if (owner_bulk_produces || owner_bulk_consumes) && m.target.threadx && !comm_thread_on {
		// the owner-side cross-core bulk service (xcore_bulk_produce/consume) is polled from the
		// comm loop; without a bus bridge there is no comm thread, so the satellite would publish
		// into a pool this image never drains (or vice versa). Fail loud rather than silently
		// generate a dead endpoint — a busless/eth-only owner needs the declarable bulk service
		// thread (docs/bulk-transport.md), not yet built.
		panic('loom2v: a cross-core [[bulk]] endpoint on this owner needs the comm thread to ' +
			'service it, but the node has no bus bridge (external signal / route / isotp) — give ' +
			'it a bus, or wait for the declarable bulk service thread')
	}
	// rx signals an FB reads flow bus -> comm(decode) -> target IOC pool cell -> FB input (6b-2b).
	// ioc_idx maps each such signal to its pool cell; visible to the comm emitter + handler glue.
	mut ioc_idx := map[string]int{}
	mut tx_cells := map[string]bool{} // the cells the comm thread reads to transmit: a live DID's source
	mut msg_ioc_idx := map[int]int{} // DBC id -> its (single) rx-read signal's IOC cell
	if comm_thread_on {
		// LAYOUT-IDENTICAL routes forward on the target (raw copy + id remap, emitted in the
		// comm loop below); routes needing a decode/re-encode transcode are still
		// deferred. parse-time already rejects a non-identical route on a threadx node, so a
		// route reaching here is raw_ident — the guard is defence in depth.
		if m.routes.any(!it.raw_ident) {
			panic('loom2v: [target] kind="threadx" comm thread: non-layout-identical routes are ' +
				'not generated yet (raw-identical route forwarding is the supported cut)')
		}
		validate_diag_threadx(m)
		validate_rx_target(m)
		rx_checked := rx_checked_msgs(m)
		// Which signals FB handlers read vs write. An rx signal READ by an FB flows through the
		// target IOC pool (6b-2b); an rx signal WRITTEN by an FB is a config error (an input isn't
		// written). Everything else external is still deferred (rejected below).
		read_count := m.fb_reads.clone() // how many FB handlers read each signal (fb_read_counts)
		mut written_count := map[string]int{} // how many FB handlers write each signal
		for fb in ecumodel.toml_arr(doc, 'fb') {
			for h in (fb.as_map()['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hm := h.as_map()
				for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
					written_count[w.string()]++
				}
			}
		}
		// EVERY remote signal is a single-writer xioc channel — including slot-only ones
		// (to a local partition), which never reach the external-TX check below: two
		// writing handlers would emit two xcore_pub(_n) producers racing the channel's
		// writer-private wseq, invalidating the tear-free algorithm (codex #211 r9).
		// NOTE: the SPSC validation itself lives in build_model and counts producer
		// CONTEXTS (threads) — a raw handler count here rejected two serial handlers
		// on one thread, a valid single producer (codex #211 r14/r15).
		// How many rx signals READ by FBs each DBC message carries (the lean whole-frame decode
		// serves one per message; more need the per-signal codec).
		mut msg_read_sigs := map[string]int{}
		for sn in m.sig_names {
			s := m.sig_of[sn] or { continue }
			if s.rx && read_count[sn] > 0 && !(m.eth != '' && s.bus == m.eth) {
				msg_read_sigs[s.dbc_msg]++
			}
		}
		for sname in m.sig_names {
			si := m.sig_of[sname] or { continue }
			// eth signals belong to the eth thread's byte IOC, never the CAN
			// owner — a mixed image must not run them through the DBC-trivial/
			// telemetry-bus battery (docs/someip.md target rung)
			if m.eth != '' && si.bus == m.eth {
				continue
			}
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
				if !si.remote && !si.dbc_trivial {
					// LOCAL producer: the lean encode writes ONE u32 at bytes 0-3. A REMOTE
					// signal is validated against the full lane contract instead
					// (dbc_lane_issue below) — its first field may be sub-u32 (codex #211 r6).
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
				// the frame fits its bus: frame_len_refusal, asked for every frame in
				// validate_signal_routes_model before this path splits
				if si.remote {
					// remote TX (satellite -> bus): the satellite image publishes into the signal's
					// xioc slot; the comm producer polls it (xcore_produce_drain) — no owner IOC cell.
					// The lean encode packs the {a, b} pair LE at bytes 0/4, so the frame must be
					// exactly the fields' width (field order = DBC layout order by convention).
					if si.dbc_lane_issue != '' {
						panic('loom2v: remote TX signal "${sname}": DBC message "${si.dbc_msg}" cannot ' +
							'carry the lane encode — ${si.dbc_lane_issue}. The lane writer fills whole ' +
							'4-byte lanes; every SG in the frame must own one (codex #211)')
					}
					if si.dbc_dlc != 4 * si.fields.len {
						panic('loom2v: remote TX signal "${sname}" has ${si.fields.len} u32 field(s) ' +
							'but DBC message "${si.dbc_msg}" DLC is ${si.dbc_dlc} — the xioc encode packs ' +
							'4 bytes per field (expect DLC ${4 * si.fields.len})')
					}
					continue
				}
				// LOCAL external tx: the lean producer encodes ONLY the value field (tv_a,
				// bytes 0-3) and the IOC cell publish carries only {val_field, 0} — a second
				// field or `valid` would silently vanish from the wire, and the SAME signal
				// would encode differently after moving to a satellite (the lane encode
				// carries every field). Placement must never silently change bytes (codex
				// #211 r4): multi-field external signals are REMOTE-ONLY until the local
				// producer encodes through the same per-field contract.
				if si.fields.len > 1 {
					panic('loom2v: [target] kind="threadx" comm thread: TX signal "${sname}" has ' +
						'${si.fields.len} field(s) ' +
						'but the LOCAL comm producer encodes only the value field — a moved-in ' +
						'satellite producer would put DIFFERENT bytes on the wire. Keep the ' +
						'producer remote, or use a single-field signal, until the encode paths unify')
				}
				ioc_idx[sname] = ioc_idx.len
				tx_cells[sname] = true
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
			// a frame the COM receive rule checks crosses to its FBs whole, through the byte IOC
			// (gen_rx_target.v) — none of the lean copy's limits below apply to it
			if si.dbc_msg in rx_checked {
				continue
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
				if si.has_status || si.lost_type != '' {
					panic('loom2v: [target] kind="threadx" comm thread: rx signal "${sname}" has a `status` ' +
						'/ `lost` field, but the lean IOC read only sets the value — an FB would see ' +
						'never_received forever; receive status on the target is rung R5 (docs/diagnostics.md)')
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
		validate_diag_live_dids(m, tx_cells)
		// [nvm]: each persistent signal stages through its own intra-core IOC
		// cell (single-writer wait-free — the proven transport, reused).
		for sname in m.nvm_names {
			ioc_idx[sname] = ioc_idx.len
		}
		// [[param]]: each parameter reaches its FBs through one cell the comm thread writes
		for p in m.params {
			ioc_idx[p.name] = ioc_idx.len
		}
	}
	// io points on the ThreadX target: the io thread and the FB thread(s) are different
	// kernel threads, so every io signal crosses through the same target IOC pool — one
	// cell per point, allocated after the comm/persist cells (docs/io.md; the host io
	// thread uses the osal channels instead).
	if m.target.threadx {
		for pt in m.io_points {
			ioc_idx[pt.name] = ioc_idx.len
		}
	}
	if ioc_idx.len > ioc_pool_n {
		panic('loom2v: [target] kind="threadx": ${ioc_idx.len} signals need target IOC ' +
			'cells (rx-to-FB + persist staging + io points), but the pool (comm_glue.c IOC_POOL_N) ' +
			'has ${ioc_pool_n} — raise both together or reduce signals')
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
		// eth signals don't create a CAN bridge — their tx loop is the
		// someip/UDP rung (this rung emits tables + codec only)
		if si.external && si.bus != m.eth {
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
	// The bridge buses that own a TRACED lane, in the manifest's numbering order. Only the P3b
	// bridge-owner shape has one today (its comm_<bb> row is where the owner's thread spans
	// resolve); every other shape leaves this empty, exactly as before. host_comm_tid derives
	// the same id the loop below stamps — trace_bridge_ids_test pins them together.
	mut bridge_bus_list := []string{}
	if tctx.on() {
		bridge_bus_list << tctx.owner_bus
	}

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
		// the io thread is a load-bearing platform thread like a bridge — its
		// busy time sums into its core's CpuLoad figure via its own slot.
		// no silent cap: a full scratch table must fail the build, not quietly
		// drop the io term from the load figure
		if m.io_points.len > 0 {
			if slot_core.len >= 16 {
				panic('telemetry scratch slots exhausted (16): the io thread needs one — reduce telemetered partitions/buses')
			}
			telem_slot['io'] = slot_core.len
			slot_core << m.io_core
		}
	}


	mp, mg := emit_module_headers(m, ecu, comm_thread_on, trace_owns_run)
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

	fb_ports, fb_glue, all_regs := emit_handlers(m, producers, ioc_idx, trace_owns_run, '', tctx)
	ports << fb_ports
	glue << fb_glue

	// --- generated COM bus bridge(s) — emitted by emit_bridges ---
	// trace_host: that runner IS the trace bus's owner, so the bus must not also get a bridge —
	// two owners on one channel, and the second one dead code nobody spawns.
	if tctx.on() && telem_on_can(m) && telem_iface != '' {
		// the owner holds exactly two channels; validate_trace_bridge_owner already refused a
		// telemetry bus that is neither.
		tctx = TraceHostCtx{
			...tctx
			telem_slots: slot_core.clone()
			telem_chan:  if m.telem.bus == tctx.trace_bus { 'trace_ch' } else { 'ch' }
		}
	}
	bridge_glue, bnames, bus_dests := emit_bridges(m, comm_thread_on, trace_owns_run, producers,
		tctx)
	glue << bridge_glue

	// --- SOME/IP eth frame table + derived-layout codec (docs/someip.md) ---
	glue << emit_eth_codec(m)
	// --- eth comm thread: SOME/IP event tx over UDP (host) ---
	if !m.target.on {
		glue << emit_eth_bridge(m)
	}
	// --- eth comm thread: SOME/IP over the NetX seam (ThreadX target) ---
	if m.target.threadx {
		glue << emit_eth_thread_target(m, doc)
	}
	mut bus_names := bnames.clone()

	// --- telemetry tx: sum per-partition load by core -> CpuLoad frame on the bus (emit_partition_telem) ---
	glue << emit_partition_telem(m, telem_iface, slot_core, trace_owns_run || tctx.on())

	// --- io: the platform io thread (docs/io.md P1, host) ---
	glue << emit_partition_io(m, producers)


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
	} else if trace_multicore {
		// The OWNER is the app partition on the trace bus's core: its ring is then genuinely local
		// to the module, so handle_cmd's arm/stop/dump and the status counts act on a real
		// producing ring instead of a staging copy (see emit_run_trace_multicore). The other
		// partition is the satellite, imported on dump.
		tb_core := m.bus_core[trace_bus] or { 0 }
		mut parts := m.part.by_part.keys().clone()
		parts.sort() // stable pick when both partitions sit on the bus core
		mut owner := ''
		for pn in parts {
			if (m.part.core_of[pn] or { 0 }) == tb_core {
				owner = pn
				break
			}
		}
		if owner == '' {
			panic('loom2v: [trace] bus "${trace_bus}" is on core ${tb_core}, but neither partition ' +
				'runs there — the dump owner is an app partition, so one of them must sit on the ' +
				'trace bus\'s core (docs/trace-multicore.md §3)')
		}
		sat := if parts[0] == owner { parts[1] } else { parts[0] }
		if (m.part.core_of[sat] or { 0 }) == tb_core {
			panic('loom2v: [trace] both partitions run on core ${tb_core} — the multi-core runner ' +
				'traces one core per partition, so give them distinct cores (or use the ' +
				'single-partition shape)')
		}
		glue << emit_run_trace_multicore(m, doc, all_regs, telem_iface, owner, sat)
	} else if trace_host {
		glue << emit_run_trace_host(m, all_regs, telem_iface, single_part)
	} else {
		glue << emit_run_host(m, telem_iface, bus_names, bus_dests, extra_dest_buses, tctx, doc)
	}
	glue << emit_bulk_glue(m.bulk, m.part, '') // '' = the bus owner image (emits every pool)

	// The `module gen` header emits `import sig` whenever the config COULD reference
	// sig.* (local cells / bus bridge / io), but some shapes don't actually — the
	// ThreadX io+bridge path hands raw u32 through the IOC, never a sig.* struct. Now
	// that the whole body exists, drop the import if nothing uses it: no unused-import
	// warning, in any config (the sig types still live in ports_gen.v).
	if !glue.any(it.contains('sig.')) {
		glue = glue.filter(it.trim_space() != 'import sig')
	}
	// likewise `import osal` (host IOC + now_us/sleep_us): a PURE-ROUTE gateway has no
	// signals and no timing, so it never calls osal.* — drop the unused import.
	if !glue.any(it.contains('osal.')) {
		glue = glue.filter(it.trim_space() != 'import osal')
	}
	// and `import ports` / `import app`: a PURE-ROUTE gateway has no FB handlers, so
	// the `app/` module may not even exist — drop the imports when nothing uses them.
	if !glue.any(it.contains('ports.')) {
		glue = glue.filter(it.trim_space() != 'import ports')
	}
	if !glue.any(it.contains('app.')) {
		glue = glue.filter(it.trim_space() != 'import app')
	}
	// the RxPublish -> RxStatus map, once, where a monitored frame publishes a status (gen_rx.v)
	if glue.any(it.contains('rx_status_of(')) {
		glue << rx_status_fn()
	}
	// and comm.com / comm.e2e, imported for what a config COULD use: a received frame's E2E state
	// now lives inside com.RxMonitor, so an rx-only E2E image may name no e2e.* at all
	for mod in ['com', 'e2e'] {
		if !refs_module(glue, mod) {
			glue = glue.filter(it.trim_space() != 'import comm.${mod}')
		}
	}

	os.write_file(args[3], signals.join('\n') + '\n') or { panic('write ${args[3]}: ${err}') }
	os.write_file(args[4], ports.join('\n') + '\n') or { panic('write ${args[4]}: ${err}') }
	os.write_file(args[5], glue.join('\n') + '\n') or { panic('write ${args[5]}: ${err}') }

	// --- ThreadX build fragment: right-size loom's Scheduler tables to this image's real
	//     per-thread handler count. The example Makefile -includes it and passes LOOM_VDEFS
	//     (-d loom_max_tasks=N) to the V transpile; loom.v's tables default to 32 on host.
	//     Derived from the same registration lists the every() calls are generated from, so
	//     the cap and the registrations cannot drift apart. ---
	if m.target.threadx {
		mut slots := 1
		for _, regs in all_regs {
			if regs.len > slots {
				slots = regs.len
			}
		}
		if xcore_on(m) || has_satellite(m) {
			// xcore_gen.h holds XCORE_LAYOUT_ID, which the cross-core boot handshake (xcore_layout_ok /
			// _publish) needs for EVERY satellite owner — even a bulk/CpuLoad-only node with no
			// cross-core [[signal]] (xcore_on false). Without this a clean `make nodes` fails on the
			// glue's #include "xcore_gen.h" (codex #235 r2); a stale header masks it on a used tree.
			hpath := os.join_path(os.dir(args[5]), 'xcore_gen.h')
			os.write_file(hpath, xcore_gen_h(m).join('\n') + '\n') or {
				panic('write ${hpath}: ${err}')
			}
		}
		mut boot_mk := ''
		if m.boot.on {
			// the node's bootloader: its config header, and the build of it (boot/boot.mk), which
			// also links the application at the board's app slot
			bus := m.isotp_conns[0].bus
			fd := (doc.value('bus').as_map()[bus] or { toml.Any(map[string]toml.Any{}) }).as_map()['fd'] or {
				toml.Any(false)
			}
			bpath := os.join_path(os.dir(args[5]), 'boot_gen.h')
			os.write_file(bpath, boot_gen_h(m, fdcan_index(bus), fd.bool()).join('\n') + '\n') or {
				panic('write ${bpath}: ${err}')
			}
			// the image key too, so `make image` refuses a signing seed this bootloader would reject
			// a [doip] node's bootloader serves DoIP too (boot/boot.mk links the network for it)
			boot_doip := if m.doip.on { 'BOOT_DOIP := 1\n' } else { '' }
			boot_mk = 'BOOT_IMAGE_KEY := ${m.boot.image_key.hex()}\n' + boot_doip + 'include ' +
				r'$(REPO)/boot/boot.mk' + ' # [boot]: make boot / image / boot-flash\n'
		}
		mkpath := os.join_path(os.dir(args[5]), 'loom_build.mk')
		os.write_file(mkpath, '# generated by loom2v from ecu.toml — do not edit\n' +
			'LOOM_VDEFS := -d loom_max_tasks=${slots}\n' + glue_build_lines(glue, m.doip.on) +
			net_build_lines(m) + fault_build_lines(m) + display_build_lines(m) + boot_mk) or {
			panic('write ${mkpath}: ${err}')
		}
	}

	// --- satellite images (docs/multi-image.md): one generated image per `image =`
	//     partition, written into its own example directory by THIS run. ---
	emit_satellite_images(m, doc, producers, ecu)

	// --- trace manifest (optional arg 6): the identity tables blobly_net loads to resolve
	//     an entity_id back to a name (emit_manifest). Built whether or not it is written: it
	//     is also where the recorder's thread-table bound is enforced. ---
	man := emit_manifest(m, doc, ecu, comm_thread_on, single_part, bridge_bus_list)
	if args.len >= 7 {
		os.write_file(args[6], man.join('\n') + '\n') or { panic('write ${args[6]}: ${err}') }
	}

	for l in wear_report {
		eprintln(l)
	}
	eprintln('loom2v: ${m.sig_names.len} signals (${bus_names.len} bus bridge), ${m.isotp_conns.len} isotp, ${m.part.by_part.len} partition(s)')
}

// refs_module: the glue names module `mod` — `mod.` at the start of an identifier, so a field of
// the same name (`st.rxm.e2e.check`) is not a reference, nor is an import line.
fn refs_module(glue []string, mod string) bool {
	pat := mod + '.'
	for line in glue {
		if line.trim_space().starts_with('import ') {
			continue
		}
		mut from := 0
		for {
			i := line.index_after(pat, from) or { break }
			if i == 0 || !(line[i - 1].is_letter() || line[i - 1].is_digit() || line[i - 1] in [`_`, `.`]) {
				return true
			}
			from = i + 1
		}
	}
	return false
}

// did_value_width is how many bytes a live DID of value type `val_type` carries — none for a type
// with no integer encoding. The one width rule: the encoder writes it, the validators ask it.
fn did_value_width(val_type string) ?int {
	return match val_type {
		'bool', 'u8', 'i8' { 1 }
		'u16', 'i16' { 2 }
		'u32', 'i32' { 4 }
		'u64', 'i64' { 8 }
		else { none }
	}
}

// validate_live_dids refuses, for every owner, a signal-backed DID that cannot be one: a value type
// with no integer encoding, or a write gate — the refresh before every dispatch would put the
// signal's value back over a write the server had just acknowledged.
fn validate_live_dids(m Model) {
	for d in m.dids {
		if d.signal == '' {
			continue
		}
		if d.writable || d.write_sessions != 0 || d.write_security != 0 {
			panic('loom2v: [[did]] 0x${d.id.hex()} reads signal "${d.signal}" and is writable — a write would be ' +
				'acknowledged and then overwritten by the next refresh; a live DID is read-only')
		}
		si := m.sig_of[d.signal] or { continue }
		if _ := did_value_width(si.val_type) {
		} else {
			panic('loom2v: [[did]] 0x${d.id.hex()} reads "${d.signal}", a ${si.val_type} — a live DID carries an integer or a bool')
		}
	}
}

// did_signal_encode emits the big-endian write of a live signal value into a DID's data buffer,
// in the width of the signal's value-field type; `srv` is the uds.Server expression.
fn did_signal_encode(srv string, idx int, expr string, val_type string) string {
	d := '${srv}.dids[${idx}]'
	if val_type == 'bool' {
		return '\t\t${d}.data[0] = if ${expr} { u8(1) } else { u8(0) }\n\t\t${d}.len = 1'
	}
	width := did_value_width(val_type) or { panic('loom2v: no live-DID encoding for ${val_type}') }
	mut lines := []string{}
	for i in 0 .. width {
		shift := 8 * (width - 1 - i)
		lines << if shift == 0 { '\t\t${d}.data[${i}] = u8(${expr})' } else { '\t\t${d}.data[${i}] = u8(${expr} >> ${shift})' }
	}
	lines << '\t\t${d}.len = ${width}'
	return lines.join('\n')
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

// dbc_msg_lane_issue checks the whole MESSAGE carrying `signame` against the lane
// encode's contract (one SG per 32-bit lane: start%32 == 0, length <= 32, unsigned,
// factor 1 / offset 0, little-endian, one SG per lane). The lane writer stores whole
// 4-byte lanes, so any other layout silently overwrites the co-resident SG. Returns ''
// when clean, else the first violation (used in the remote-TX walk panic).
fn dbc_msg_lane_issue(db candb.Database, signame string, nlanes int, widths []int) string {
	for m in db.messages {
		for s in m.signals {
			if s.name != signame {
				continue
			}
			// the [[signal]].name SG anchors the frame: the publisher writes field 0 to
			// lane 0, and the named SG is the one the declaration binds — anywhere else
			// and every field lands under the wrong DBC name (codex #211 r9; this is the
			// binding the old 32-bit-at-bit-0 check gave, generalized)
			if s.start_bit != 0 {
				return 'signal "${signame}" (the [[signal]].name binding) sits at bit ${s.start_bit} — it must own lane 0 (bit 0)'
			}
			mut lanes_used := map[int]string{}
			for sg in m.signals {
				if sg.start_bit % 32 != 0 {
					return 'signal "${sg.name}" starts at bit ${sg.start_bit} (not a 32-bit lane boundary)'
				}
				if sg.length > 32 {
					return 'signal "${sg.name}" is ${sg.length} bits (a lane carries <= 32)'
				}
				if sg.is_signed || sg.factor != 1.0 || sg.offset != 0.0 {
					return 'signal "${sg.name}" is signed/scaled — the lane encode writes raw u32 values'
				}
				if sg.byte_order != candb.ByteOrder.little_endian {
					return 'signal "${sg.name}" is big-endian (Motorola) — lanes are LE'
				}
				lane := int(sg.start_bit / 32)
				if prev := lanes_used[lane] {
					return 'signals "${prev}" and "${sg.name}" share lane ${lane} — the lane writer fills whole lanes'
				}
				// the SG must be at least as wide as the field it carries: a u16 field over
				// an 8-bit SG would leak its upper byte into bits the DBC calls reserved —
				// moving the producer must never change the wire frame (codex #211 r7)
				if lane < widths.len && sg.length < widths[lane] {
					return 'signal "${sg.name}" is ${sg.length} bits but lane ${lane} carries a ${widths[lane]}-bit field — widen the SG or narrow the field'
				}
				lanes_used[lane] = sg.name
			}
			// every lane must be OWNED: a field written into a lane no SG declares is
			// undecodable padding on every receiver (codex #211 r6)
			for lane in 0 .. nlanes {
				if lane !in lanes_used {
					return 'lane ${lane} (bytes ${lane * 4}-${lane * 4 + 3}) has no DBC signal — the lane writer fills it, receivers cannot decode it'
				}
			}
			return ''
		}
	}
	return ''
}

// dbc_lanes: for lane 0..n-1 of the message carrying `signame`, the DBC signal that owns it — lane 0
// the signal itself, by name; lane j > 0 the one starting at bit 32 * j (dbc_msg_lane_issue refuses a
// lane-encoded message where that is not exactly one signal). A name of '' where none does.
fn dbc_lanes(db candb.Database, signame string, n int) []candb.Signal {
	mut out := []candb.Signal{len: n}
	for m in db.messages {
		if !m.signals.any(it.name == signame) {
			continue
		}
		for sg in m.signals {
			if sg.name == signame {
				out[0] = sg
			} else if sg.start_bit % 32 == 0 && sg.start_bit > 0 && sg.start_bit / 32 < n {
				out[sg.start_bit / 32] = sg
			}
		}
		break
	}
	return out
}

// lane_encode_lines: lane `j` of signal `si` — `cell`, a u32 an FB published (`u32(field)`) — through
// the one send encode (candb encode_lines: comm/com encode_raw, rounded and held to its DBC signal's
// range, a VAL_ entry let through), its raw bits written little-endian into `frame`.data at byte 4j, a
// saturation added to `sat`. A lane signal is unsigned, LE, at most 32 bits at bit 32j (the lean and
// lane contracts: dbc_signal_trivial, dbc_msg_lane_issue), so those bytes are exactly its bits.
fn lane_encode_lines(si SigInfo, j int, typ string, cell string, frame string, sat string, ind string) []string {
	sg := si.dbc_lanes[j] or { candb.Signal{} }
	if sg.name == '' {
		panic('loom2v: TX signal "${si.name}": lane ${j} of DBC message "${si.dbc_msg}" has no signal')
	}
	if typ !in lane_field_types {
		panic('loom2v: [target] kind="threadx": TX signal "${si.name}" field ${j} is a ${typ}, but a comm-thread producer carries a field as a u32 (`u32(field)`), which keeps neither a wider integer nor a fraction — use ${lane_field_types.join(' / ')}')
	}
	rr := sg.raw_range() or { panic('loom2v: TX signal "${si.name}": ${err}') }
	if rr.note != '' {
		panic('loom2v: TX signal "${si.name}": DBC signal "${sg.name}" ${rr.note} — a sent value is held to its signal\'s range, so the range must be one a value can be sent in')
	}
	v := '${frame.replace('.', '_')}_raw${j}'
	mut g := sg.encode_lines(cell_phys(typ, cell), v, '${v}_sat', ind) or {
		panic('loom2v: TX signal "${si.name}": ${err}')
	}
	for b in 0 .. 4 {
		g << if b == 0 {
			'${ind}${frame}.data[${4 * j}] = u8(${v})'
		} else {
			'${ind}${frame}.data[${4 * j + b}] = u8(${v} >> ${8 * b})'
		}
	}
	g << '${ind}if ${v}_sat {'
	g << '${ind}\t${sat}++'
	g << '${ind}}'
	return g
}

// pdu_init_lines: THE one place a sent frame's initial payload is emitted — `frame`.data set to the
// DBC message's bytes with every signal at its initial value (SigInfo.dbc_init: candb init_payload,
// GenSigStartValue or the in-range value nearest 0), so a field nobody has published yet goes out in
// range rather than as raw 0 (REQ-COM-011). Every byte of the DLC is written, so a frame variable
// reused across messages carries nothing over. The host bridge, the target's local producers and its
// satellite lanes all start from it; an initial value is never counted as a saturation.
fn pdu_init_lines(si SigInfo, frame string, ind string) []string {
	if si.dbc_init.len == 0 {
		return []string{}
	}
	mut g := ['${ind}// initial payload of ${si.dbc_msg}: every signal at its initial value (REQ-COM-011)']
	for i, b in si.dbc_init {
		g << '${ind}${frame}.data[${i}] = u8(0x${b:02x})'
	}
	return g
}

// lane_field_types: what a u32 IOC cell or lane carries whole (`u32(field)` and back).
const lane_field_types = ['bool', 'u8', 'u16', 'u32', 'i8', 'i16', 'i32']

// cell_phys: the physical value an FB published into a u32 IOC cell or lane (`u32(field)`, a bool
// as 0 / 1), as the f64 com.encode_raw takes — a signed field read back through its sign.
fn cell_phys(typ string, expr string) string {
	return match typ {
		'i8', 'i16', 'i32' { 'f64(i32(${expr}))' }
		else { 'f64(${expr})' }
	}
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
	// single source: ecumodel.snake_name — the validator's collision checks
	// and this generator's emitted identifiers must agree byte-for-byte
	return ecumodel.snake_name(name)
}

// ms_to_us converts an authored timeout to the µs the generated code holds in an int, refusing a
// negative value and one whose µs would not fit (a wrap would turn a long timeout negative, and a
// non-positive timeout silently switches the monitor off).
fn ms_to_us(ms i64, what string) int {
	if ms < 0 {
		panic('loom2v: ${what} ${ms} is negative (0 = none)')
	}
	if ms > i64(max_i32) / 1000 { // compared in ms: `ms * 1000` itself could overflow i64
		panic('loom2v: ${what} ${ms} is too long (at most ${i64(max_i32) / 1000} ms)')
	}
	return int(ms * 1000)
}

// validate_e2e_timeouts: the E2E-owned timeout (REQ-E2E-002, ASIL B), checked ONCE against the whole
// model — every bus, used or not. It is REQUIRED on an E2E frame whose signals the bridge delivers
// to the application, and each of those signals must carry `status`, or its expiry would publish
// a zero value indistinguishable from a healthy one. It comes from `e2e.timeout_ms` or the DBC's
// `E2ETimeout`; one AUTHORED in ecu.toml is refused where nothing receives the frame (transmitted,
// or neither decoded nor a signal route's source), while the DBC's is for whoever receives it.
fn validate_e2e_timeouts(m Model) {
	// the SOME/IP receive path (#299): the same two requirements, per received eth E2E frame —
	// every eth signal received reaches the application, so there is no decoded-or-not question
	for fr in m.eth_frames {
		if fr.tx {
			continue
		}
		if !fr.e2e_on {
			// nothing on an unprotected eth frame can report timeout or integrity (no COM deadline
			// on eth): a status there would read ok forever over a stale value
			for sn in fr.signals {
				si := m.sig_of[sn] or { SigInfo{} }
				if si.has_status {
					panic('loom2v: signal "${sn}" has a `status`, but eth frame "${fr.name}" is not E2E-protected — on the SOME/IP path only E2E can report a timeout or an integrity failure, so the status would read ok forever')
				}
				if si.lost_type != '' {
					panic('loom2v: signal "${sn}" has a `lost` counter, but eth frame "${fr.name}" is not E2E-protected — only the E2E sequence check can count lost frames')
				}
			}
			continue
		}
		if fr.e2e_tmo_us == 0 {
			panic('loom2v: eth frame "${fr.name}" is E2E-protected and received, but its e2e has no timeout_ms — REQ-E2E-002 detects total loss of the sender inside E2E itself')
		}
		for sn in fr.signals {
			if !(m.sig_of[sn] or { SigInfo{} }).has_status {
				panic('loom2v: signal "${sn}" comes from the E2E-protected eth frame "${fr.name}" but has no `status = "RxStatus"` — without it an E2E timeout reaches the FB as a zero value that looks healthy')
			}
		}
	}
	mut delivered := map[string][]string{} // frame -> the received signals decoded from it
	for sname in m.sig_names {
		si := m.sig_of[sname] or { continue }
		if si.external && si.rx && m.frames.e2e_here(si.dbc_msg, si.bus) {
			delivered[si.dbc_msg] << sname
		}
	}
	route_src := m.routes.filter(it.signal != '' && m.frames.e2e_here(snake(it.from_frame), it.from_bus)).map(snake(it.from_frame))
	for fk, to in m.frames.e2e_timeout_us {
		// the DBC's E2ETimeout is for whoever receives the frame, so only an authored one is refused
		if to > 0 && fk !in delivered && fk !in route_src && m.frames.e2e_timeout_authored[fk] {
			panic('loom2v: frame "${fk}" sets e2e.timeout_ms, but nothing receives it — the E2E timeout watches a RECEIVED frame for loss of its sender')
		}
	}
	for fk, sigs in delivered {
		if bad := m.frames.e2e_timeout_bad[fk] {
			panic('loom2v: frame "${fk}" is E2E-protected and received, and its E2ETimeout "${bad}" in the DBC is not a number of ms — fix it, or set e2e.timeout_ms')
		}
		if (m.frames.e2e_timeout_us[fk] or { 0 }) == 0 {
			panic('loom2v: frame "${fk}" is E2E-protected and received, but has no E2E timeout (e2e.timeout_ms, or E2ETimeout in the DBC) — REQ-E2E-002 detects total loss of the sender inside E2E itself, not only by the QM COM deadline')
		}
		for sname in sigs {
			if !(m.sig_of[sname] or { SigInfo{} }).has_status {
				panic('loom2v: signal "${sname}" comes from the E2E-protected frame "${fk}" but has no `status = "RxStatus"` — without it an E2E timeout reaches the FB as a zero value that looks healthy')
			}
		}
	}
}

// FaultCfg is one [[fault]] (docs/diagnostics.md §3.3): a DTC, the FB handler that tests it, how its
// results are debounced (on that handler's thread), the enable conditions, and the confirmation /
// aging thresholds the fault memory applies.
struct FaultCfg {
	name       string
	dtc        int
	fb         string
	handler    string
	time_based bool
	fail_thr   int // counter: results; time: µs
	pass_thr   int
	inc        int  // counter: step per failed result (AUTOSAR-shaped; default 1)
	dec        int  // counter: step per passed result (default 1)
	jump       bool // counter: reset to 0 on a reversal ("N in a row"); default accumulates
	enable     []string // "Signal.field" (bool) the handler reads
	confirm    int
	aging      int
	freeze     []int // the snapshot: [[did]]s captured at the failure that allocates an entry
	priority   int   // displacement: 1 = the most important .. 255
	snapshot_ids []int // the snapshot's two journal blocks A, B pinned (empty = derived from the DTC and schema)
	// a SIGNAL-STATUS fault (R4c): no FB tests it — the diagnostic bridge is the detector, from the
	// named received signal's status: on = "timeout" | "integrity" | "lost"
	signal string
	on     string
}

fn parse_faults(doc toml.Doc) []FaultCfg {
	mut out := []FaultCfg{}
	for f in ecumodel.toml_arr(doc, 'fault') {
		m := f.as_map()
		name := (m['name'] or { toml.Any('') }).string()
		mut freeze := []int{}
		for d in (m['freeze'] or { toml.Any([]toml.Any{}) }).array() {
			freeze << int(d.i64())
		}
		if 'snapshot_id' in m {
			panic('loom2v: [[fault]] "${name}": `snapshot_id` is `snapshot_ids = [A, B]` — both of the snapshot\'s blocks')
		}
		mut snapshot_ids := []int{}
		for v in (m['snapshot_ids'] or { toml.Any([]toml.Any{}) }).array() {
			snapshot_ids << int(v.i64())
		}
		if 'snapshot_ids' in m {
			if snapshot_ids.len != 2 || snapshot_ids[0] == snapshot_ids[1]
				|| snapshot_ids.any(!schema_key('fault', 'snapshot_ids').in_range(it)) {
				panic('loom2v: [[fault]] "${name}": snapshot_ids must be two distinct ids in ${schema_key('fault',
					'snapshot_ids').min}..${schema_key('fault', 'snapshot_ids').max} — blocks A and B')
			}
			if freeze.len == 0 {
				panic('loom2v: [[fault]] "${name}": snapshot_ids pins snapshot blocks, but the fault declares no `freeze`')
			}
		}
		priority := (m['priority'] or { toml.Any(default_fault_priority) }).i64()
		pk := schema_key('fault', 'priority')
		if !pk.in_range(priority) {
			panic('loom2v: [[fault]] "${name}": priority ${priority} must be ${pk.min} (the most important) .. ${pk.max}')
		}
		signal := (m['signal'] or { toml.Any('') }).string()
		on := (m['on'] or { toml.Any('') }).string()
		from := (m['from'] or { toml.Any('') }).string()
		mut parts := ['', '']
		if signal != '' || on != '' {
			// a signal-status fault: the bridge tests it, so there is no handler and no enable
			if from != '' || 'enable' in m {
				panic('loom2v: [[fault]] "${name}": a signal-status fault (signal / on) is tested by the bridge — it takes no `from` or `enable`')
			}
			ons := schema_key('fault', 'on').choices
			if signal == '' || on !in ons {
				on_list := ons.map('"' + it + '"').join(' | ')
				panic('loom2v: [[fault]] "${name}": a signal-status fault needs signal = "<received signal>" and on = ${on_list}')
			}
		} else {
			parts = from.split('.')
			if parts.len != 2 || parts[0] == '' || parts[1] == '' {
				panic('loom2v: [[fault]] "${name}": from = "${from}" must name the testing handler as "Fb.handler" (or use signal / on for a signal-status fault)')
			}
		}
		db := (m['debounce'] or { toml.Any(map[string]toml.Any{}) }).as_map()
		kind := (db['kind'] or { toml.Any('counter') }).string()
		kinds := schema_key('fault_debounce', 'kind').choices
		if kind !in kinds {
			panic('loom2v: [[fault]] "${name}": debounce kind "${kind}" is not ${kinds.join(' / ')}')
		}
		time_based := kind == 'time'
		// each kind has its own keys, and a time threshold has no sane default: a missing fail_ms
		// would mean 0 µs — no debounce at all — so both are required
		other_keys := if time_based { ['fail', 'pass', 'inc', 'dec', 'jump'] } else { ['fail_ms', 'pass_ms'] }
		for key in other_keys {
			if key in db {
				panic('loom2v: [[fault]] "${name}": debounce.${key} does not belong to kind = "${kind}"')
			}
		}
		if time_based && (!('fail_ms' in db) || !('pass_ms' in db)) {
			panic('loom2v: [[fault]] "${name}": a time debounce needs fail_ms and pass_ms')
		}
		fail_thr := if time_based {
			ms_to_us((db['fail_ms'] or { toml.Any(0) }).i64(), '[[fault]] "${name}" debounce.fail_ms')
		} else {
			counter_thr((db['fail'] or { toml.Any(1) }).i64(), name, 'fail')
		}
		pass_thr := if time_based {
			ms_to_us((db['pass_ms'] or { toml.Any(0) }).i64(), '[[fault]] "${name}" debounce.pass_ms')
		} else {
			counter_thr((db['pass'] or { toml.Any(1) }).i64(), name, 'pass')
		}
		inc := if time_based { 1 } else { counter_thr((db['inc'] or { toml.Any(1) }).i64(), name, 'inc') }
		dec := if time_based { 1 } else { counter_thr((db['dec'] or { toml.Any(1) }).i64(), name, 'dec') }
		// fail = 1 says one failed result IS the verdict (AUTOSAR's monitor-internal debouncing), so
		// it jumps by default: accumulating, a healed counter at -pass would need pass+1 failures to
		// reach +1, and a one-shot event could never qualify. Real fail thresholds accumulate.
		jump := (db['jump'] or { toml.Any(!time_based && fail_thr == 1) }).bool()
		if fail_thr < 1 || pass_thr < 1 || (!time_based && (fail_thr > 0xFFFF || pass_thr > 0xFFFF)) {
			panic('loom2v: [[fault]] "${name}": debounce thresholds must be at least 1 (counter: 1..65535 results; time: >= 1 ms)')
		}
		mut enable := []string{}
		for e in (m['enable'] or { toml.Any([]toml.Any{}) }).array() {
			enable << e.string()
		}
		// read wide and range-check before narrowing: a truncating read could wrap a typo into range
		confirm := (m['confirm'] or { toml.Any(1) }).i64()
		aging := (m['aging'] or { toml.Any(0) }).i64()
		dtc := (m['dtc'] or { toml.Any(0) }).i64()
		dk := schema_key('fault', 'dtc')
		if !dk.in_range(dtc) {
			panic('loom2v: [[fault]] "${name}": dtc 0x${dtc.hex()} is not a 3-byte DTC (${dk.min}..0x${dk.max:X})')
		}
		ck := schema_key('fault', 'confirm')
		ak := schema_key('fault', 'aging')
		if !ck.in_range(confirm) || !ak.in_range(aging) {
			panic('loom2v: [[fault]] "${name}": confirm must be ${ck.min}..${ck.max} and aging ${ak.min}..${ak.max} (0 = never ages)')
		}
		out << FaultCfg{
			name:       name
			dtc:        int(dtc)
			fb:         parts[0]
			handler:    parts[1]
			time_based: time_based
			fail_thr:   fail_thr
			pass_thr:   pass_thr
			inc:        inc
			dec:        dec
			jump:       jump
			enable:     enable
			confirm:    int(confirm)
			aging:      int(aging)
			signal:     signal
			on:         on
			freeze:     freeze
			priority:   int(priority)
			snapshot_ids: snapshot_ids
		}
	}
	return out
}

// default_fault_priority: a [[fault]] without `priority` — the middle of AUTOSAR's 1..255
const default_fault_priority = 128

fn parse_fault_cycle(doc toml.Doc) string {
	fm := doc.value_opt('fault_memory') or { return '' }
	return (fm.as_map()['cycle'] or { toml.Any('') }).string()
}

// parse_fault_entries: [fault_memory] entries, -1 when absent (validate_fault_snapshots defaults it)
fn parse_fault_entries(doc toml.Doc) int {
	fm := doc.value_opt('fault_memory') or { return -1 }
	return int((fm.as_map()['entries'] or { toml.Any(-1) }).i64())
}

// fault_fbs: the FBs that own faults, in first-declaration order — each gets one report cell (its
// thread writes) and one control cell (the diagnostic bridge writes); cfg2v allocates both.
fn fault_fbs(m Model) []string {
	return ecumodel.fault_fbs(m.faults.filter(it.signal == '').map('${it.fb}.${it.handler}'))
}

// fault_sources: the received signals signal-status faults watch, in first-declaration order.
fn fault_sources(m Model) []string {
	mut out := []string{}
	for f in m.faults {
		if f.signal != '' && f.signal !in out {
			out << f.signal
		}
	}
	return out
}

// validate_faults: everything a [[fault]] needs, refused at generation when missing.
fn validate_faults(m Model, doc toml.Doc) {
	if m.faults.len == 0 {
		if m.fault_cycle != '' {
			panic('loom2v: [fault_memory] is declared but there is no [[fault]]')
		}
		return
	}
	if m.target.on && !m.target.threadx {
		panic('loom2v: [[fault]] on a bare-metal [target] — the fault memory runs on a ThreadX comm thread (docs/diagnostics.md R6); use kind = "threadx"')
	}
	if m.isotp_conns.len != 1 {
		panic('loom2v: [[fault]] needs the node\'s diagnostic server — an [isotp] connection — to serve 0x19 / 0x14 / 0x85')
	}
	if m.faults.len > fault.max_faults {
		panic('loom2v: ${m.faults.len} [[fault]]s exceed the fault memory (${fault.max_faults})')
	}
	mut names := map[string]bool{}
	mut dtcs := map[int]string{}
	mut per_fb := map[string]int{}
	// the snake form becomes a field of the FB's Faults struct: one scope per FB
	mut scopes := map[string]ecumodel.SnakeScope{}
	for f in m.faults {
		if !ecumodel.pascal_ok(f.name) || f.name in names {
			panic('loom2v: [[fault]] name "${f.name}" is not PascalCase ([A-Z][A-Za-z0-9]*), or is declared twice')
		}
		names[f.name] = true
		if f.fb !in scopes {
			scopes[f.fb] = ecumodel.snake_scope('fault of ${f.fb}')
		}
		if e := scopes[f.fb].add(f.name) {
			panic('loom2v: [[fault]] ${e}')
		}
		thr := m.part.fb_thread[f.fb] or { '' }
		if m.part.external[m.part.thread_part[thr] or { '' }] or { false } {
			panic('loom2v: [[fault]] "${f.name}": ${f.fb} lives in a partition this image does not generate — its debounce and report cell would never be emitted')
		}
		if prev := dtcs[f.dtc] {
			panic('loom2v: [[fault]] "${f.name}": dtc 0x${f.dtc.hex()} is already "${prev}" — a DTC is unique per diagnostic server')
		}
		dtcs[f.dtc] = f.name
		if f.signal != '' {
			validate_signal_fault(m, f)
			continue
		}
		per_fb[f.fb]++
		if per_fb[f.fb] > fault.max_per_producer {
			panic('loom2v: fb "${f.fb}" owns more than ${fault.max_per_producer} faults — its report cell (one IOC payload) holds that many')
		}
		reads := handler_reads(doc, f.fb, f.handler) or {
			panic('loom2v: [[fault]] "${f.name}": from = "${f.fb}.${f.handler}" names no FB handler')
		}
		for e in f.enable {
			bool_field_of(m, e, 'enable condition of [[fault]] "${f.name}"')
			if e.all_before('.') !in reads {
				panic('loom2v: [[fault]] "${f.name}": enable condition "${e}" — the handler ${f.fb}.${f.handler} does not read ${e.all_before('.')}; the condition is evaluated on the testing thread, so it must be one of its inputs')
			}
		}
	}
	validate_fault_snapshots(m)
	if m.target.on {
		validate_fault_target(m)
		return
	}
	if m.fault_cycle == '' {
		panic('loom2v: [[fault]] needs an operation cycle: [fault_memory] cycle = "Signal.field" (a bool), or "power" — the host bridge runs no NM, so nothing else starts and ends a cycle (decision D3)')
	}
	if m.fault_cycle == fault_cycle_power {
		return
	}
	bool_field_of(m, m.fault_cycle, '[fault_memory] cycle')
	cs := m.sig_of[m.fault_cycle.all_before('.')] or { SigInfo{} }
	if !(cs.external && cs.rx && cs.bus == m.isotp_conns[0].bus) {
		panic('loom2v: [fault_memory] cycle "${m.fault_cycle}" must be a signal received on the diagnostic bus "${m.isotp_conns[0].bus}" — the bridge that owns the fault memory reads it')
	}
}

// fault_freeze_lens: the byte size of each of fault f's snapshot DIDs — a constant DID's bytes, a
// live one's value width — the fixed shape its snapshot record has (comm/fault capture zero-fills
// or cuts a DID to it).
fn fault_freeze_lens(m Model, f FaultCfg) []int {
	mut out := []int{}
	for id in f.freeze {
		mut n := 0
		for d in m.dids {
			if d.id == id {
				n = if d.signal != '' {
					did_value_width((m.sig_of[d.signal] or { SigInfo{} }).val_type) or { 0 }
				} else if d.param != '' || d.param_status {
					param_did_len(m, d)
				} else {
					d.bytes.len
				}
			}
		}
		out << n
	}
	return out
}

// fault_entries: the snapshot entries the memory holds — declared, or one per fault with a
// snapshot (at most fault.max_entries).
fn fault_entries(m Model) int {
	if m.fault_entries >= 0 {
		return m.fault_entries
	}
	n := m.faults.filter(it.freeze.len > 0).len
	return if n > fault.max_entries { fault.max_entries } else { n }
}

// validate_fault_snapshots: every owner's snapshot rules. A snapshot names declared [[did]]s,
// each at most once, at most fault.max_freeze of them, none empty. And it is no side door around
// DID access (docs/diagnostics.md §7): 0x19 04 hands out what the DIDs hold under 0x19's own
// gate, so each DID must be readable in every session 0x19 is served in, behind no 0x27 level but
// the one 0x19's row itself demands.
fn validate_fault_snapshots(m Model) {
	row, _ := svc_row(m, 0x19)
	// a 0 mask is every session — every one an application server enters (never programming)
	app := uds.in_default | uds.in_extended | uds.in_safety
	served := if row.sessions == 0 { app } else { row.sessions & app }
	mut snaps := 0
	for f in m.faults {
		if f.freeze.len == 0 {
			continue
		}
		snaps++
		if f.freeze.len > fault.max_freeze {
			panic('loom2v: [[fault]] "${f.name}": freeze names ${f.freeze.len} DIDs — a snapshot holds at most ${fault.max_freeze} (comm/fault max_freeze)')
		}
		mut seen := []int{}
		for id in f.freeze {
			if id in seen {
				panic('loom2v: [[fault]] "${f.name}": freeze names DID 0x${id.hex()} twice')
			}
			seen << id
			d := m.dids.filter(it.id == id)
			if d.len == 0 {
				panic('loom2v: [[fault]] "${f.name}": freeze DID 0x${id.hex()} is not a [[did]] of this node — a snapshot is read from the diagnostic server\'s own DIDs')
			}
			readable := if d[0].read_sessions == 0 { app } else { d[0].read_sessions }
			if readable & served != served {
				panic('loom2v: [[fault]] "${f.name}": freeze DID 0x${id.hex()} is not readable in every session 0x19 is served in — 0x19 04 would hand it out where 0x22 refuses it')
			}
			if d[0].read_security != 0 && d[0].read_security != row.security {
				panic('loom2v: [[fault]] "${f.name}": freeze DID 0x${id.hex()} is read behind 0x27 level ${d[0].read_security}, which 0x19 does not demand — 0x19 04 would hand it out without the unlock')
			}
		}
		for i, n in fault_freeze_lens(m, f) {
			if n == 0 {
				panic('loom2v: [[fault]] "${f.name}": freeze DID 0x${f.freeze[i].hex()} holds no bytes — nothing to capture')
			}
		}
	}
	if m.fault_entries >= 0 {
		if snaps == 0 {
			panic('loom2v: [fault_memory] entries: no [[fault]] declares a snapshot (`freeze`) to keep in them')
		}
		if !schema_key('fault_memory', 'entries').in_range(m.fault_entries) {
			panic('loom2v: [fault_memory] entries = ${m.fault_entries} must be 1 .. ${fault.max_entries} (comm/fault max_entries)')
		}
	}
}

// fault_cycle_power: `[fault_memory] cycle = "power"` — the operation cycle is the power cycle: it
// begins when the owner starts and ends with it (AUTOSAR's POWER cycle), for a node with neither NM
// nor a cycle signal. With the memory in RAM its end is never observed: pending never clears and
// nothing ages until the persistent memory records the shutdown (R6, docs/diagnostics.md §3.3).
const fault_cycle_power = 'power'

// iocb_pool_n: the byte-IOC channels a ThreadX image has (boards/common/iocb.c IOCB_POOL_N),
// shared by the eth signals, the checked received signals and the fault cells (iocb_overflow).
const iocb_pool_n = 8

// validate_fault_target: what a ThreadX image's fault memory needs beyond the host's rules. The
// memory runs on the comm thread (D2) — the owner of the diagnostic connection, which
// validate_diag_threadx keeps on that thread's bus; each fault-owning FB reaches it through two
// byte-IOC cells (fault_cell). The operation cycle is NM's wake -> bus sleep (D3's default), or
// "power"; a cycle SIGNAL is not generated there yet: the comm thread keeps no edge state for one
// (the host bridge's rx_group_hooks cycle edges are not wired on the target).
fn validate_fault_target(m Model) {
	if m.fault_cycle == '' && !m.nm.on {
		panic('loom2v: [[fault]] on the target needs an operation cycle: [nm] (D3\'s default, wake -> bus sleep) or [fault_memory] cycle = "power"')
	}
	if m.fault_cycle != '' && m.fault_cycle != fault_cycle_power {
		panic('loom2v: [fault_memory] cycle "${m.fault_cycle}": a cycle signal on the target is not generated yet — the comm thread decodes no bool it could watch; leave cycle out for NM (D3) or write cycle = "power"')
	}
	if !m.nvm.on {
		panic('loom2v: [[fault]] on the target needs [nvm] — the fault memory keeps its DTCs, counters and snapshots in the NvM journal across resets and power loss (docs/diagnostics.md §3.3); declare the storage')
	}
	if why := iocb_overflow(m) {
		panic('loom2v: [[fault]]: ${why}')
	}
}

// fault_cell: the byte-IOC channel of `fb`'s report cell (its thread writes) or control cell (the
// comm thread writes) on a ThreadX image — after the eth signals' channels, two per fault-owning FB
// in first-declaration order. The one numbering the FB glue, the comm thread and boot share.
fn fault_cell(m Model, fb string, control bool) int {
	k := fault_fbs(m).index(fb)
	if k < 0 {
		panic('loom2v: no fault cell for ${fb}')
	}
	return rx_iocb_idx(m).len + 2 * k + if control { 1 } else { 0 }
}

// fault_target_on: the image runs a fault memory on its ThreadX comm thread (R6).
fn fault_target_on(m Model) bool {
	return m.target.threadx && m.faults.len > 0
}

// iocb_on: the image uses the byte IOC pool — its eth signals, its fault cells, or both.
fn iocb_on(m Model) bool {
	return eth_thread_on(m) || fault_target_on(m) || rx_iocb_idx(m).len > 0
}

// fault_target_globals: the fault memory and each fault-owning FB's two cells, comm-thread side,
// in bss (no field defaults: the _vinit rule) — the memory is ~1 KB, too much for the stack.
fn fault_target_globals(m Model) []string {
	if !fault_target_on(m) {
		return []string{}
	}
	mut g := ['\tg_fmem fault.Memory // the node\'s fault memory: the comm thread is its one writer (D2)']
	if m.nm.on && m.fault_cycle == '' {
		g << '\tg_fcycle_on bool // NM awake as last seen: the operation cycle (D3)'
	}
	for fb in fault_fbs(m) {
		f := snake(fb)
		g << '\tg_frep_${f} fault.Reports // from ${fb}\'s thread'
		g << '\tg_fctl_${f} fault.Control // to ${fb}\'s thread'
	}
	return g
}

// fault_target_init: the memory configured and handed to the server, after the connection is.
fn fault_target_init(m Model) []string {
	if !fault_target_on(m) {
		return []string{}
	}
	mut g := fault_slot_lines(m, 'g_fmem', '\t')
	g << fault_memory_init_lines(m, 'g_fmem', 'g_diag.server', '\t', fault_store_lines(m, 'g_fmem',
		'\t'))
	return g
}

// fault_target_pass: the memory's share of the comm-thread pass, at its TOP — after the
// connection's housekeeping, before the drain where requests are served — so every 0x19 reads the
// newest reports, and every clear reaches the producers the pass it is made.
fn fault_target_pass(m Model) []string {
	if !fault_target_on(m) {
		return []string{}
	}
	mut g := fault_target_consume(m, '\t\t')
	g << fault_capture_lines(m, 'g_fmem', 'g_diag', '\t\t')
	return g
}

// fault_target_persist: what the memory changed this pass, written to the journal — after the
// operation cycle's step, before the NvM service's sleep-edge flush. A write made while the bus
// sleeps re-runs the whole flush choreography, so the journal's clean marker never sits below a
// record it does not cover (REQ-NVM-014's rule, the persisted signals' own).
fn fault_target_persist(m Model, ioc_idx map[string]int) []string {
	if !fault_persist_on(m) {
		return []string{}
	}
	// never an erase here: on a node without NM the journal erases only at boot, before the kernel
	// (nvm_boot_lines), and one with NM only in its sleep edges' choreography
	mut g := ['\t\tg_fmem.persist(t1, false) // what changed: unwritten snapshots, the status image, tombstones']
	if m.nm.on && m.params.len > 0 {
		// a parameter coded this pass too: ONE choreography for both writers
		g << '\t\tparam_wrote := g_param.take_wrote()'
		g << '\t\tif (g_fmem.wrote > 0 || param_wrote) && g_nm.state() == .bus_sleep {'
		g << nvm_flush_choreo(m, ioc_idx, '\t\t\t')
		g << '\t\t}'
	} else if m.nm.on {
		g << '\t\tif g_fmem.wrote > 0 && g_nm.state() == .bus_sleep {'
		g << nvm_flush_choreo(m, ioc_idx, '\t\t\t')
		g << '\t\t}'
	}
	return g
}

// fault_target_consume: every fault-owning FB's reports read and consumed, and the clear
// generations sent back — the pass top's, and again just before NM ends the cycle.
fn fault_target_consume(m Model, ind string) []string {
	mut g := []string{}
	for fb in fault_fbs(m) {
		f := snake(fb)
		g << '${ind}C.iocb_get(${fault_cell(m, fb, false)}, &g_frep_${f}) // ${fb}\'s debounced reports'
		g << fault_consume_lines(m, fb, 'g_fmem', 'g_frep_${f}', 'g_fctl_${f}', ind)
		g << '${ind}C.iocb_pub(${fault_cell(m, fb, true)}, &g_fctl_${f})'
	}
	return g
}

// fault_target_cycle: D3's default operation cycle — NM's wake begins it and bus sleep ends it —
// after the NM tick, so this pass's state is the one acted on. What the FBs reported since the pass
// top is consumed before the cycle ends, so a result from the cycle's last dispatches lands inside
// it (the host's falling edge follows its frame's results the same way, rx_group_hooks).
fn fault_target_cycle(m Model, now string, ind string) []string {
	if !fault_target_on(m) || !m.nm.on || m.fault_cycle != '' {
		return []string{}
	}
	// bus sleep REQUESTS the end: the cycle stays open for the barrier's grace, so a report a
	// dispatch from before the edge publishes after this pass's read still lands in it (§7)
	mut g := [
		'${ind}if g_nm.awake() != g_fcycle_on { // the operation cycle follows NM (D3)',
		'${ind}\tg_fcycle_on = g_nm.awake()',
		'${ind}\tif g_fcycle_on {',
		'${ind}\t\tif g_fmem.ending { // woken inside the grace: what the ending cycle saw is read into it first',
	]
	g << fault_target_consume(m, ind + '\t\t\t')
	g << fault_capture_lines(m, 'g_fmem', 'g_diag', ind + '\t\t\t')
	g << [
		'${ind}\t\t}',
		'${ind}\t\tg_fmem.cycle_start()',
		'${ind}\t} else {',
		'${ind}\t\tg_fmem.end_cycle_after(${now}, u64(${m.fault_grace_us})) // the cycle-end barrier: the producers publish first',
		'${ind}\t}',
		'${ind}}',
		'${ind}if g_fmem.cycle_end_due(${now}) {',
	]
	g << fault_target_consume(m, ind + '\t')
	g << fault_capture_lines(m, 'g_fmem', 'g_diag', ind + '\t')
	g << [
		'${ind}\tg_fmem.cycle_end()',
		'${ind}}',
	]
	return g
}

// fault_grace_us: the cycle-end barrier's grace — twice the longest period of a handler that tests
// a fault, so every dispatch begun before the end has published its report by then.
fn fault_grace_us(m Model, doc toml.Doc) u64 {
	mut longest := u64(0)
	for c in ecumodel.toml_arr(doc, 'fb') {
		cm := c.as_map()
		fb := (cm['name'] or { toml.Any('') }).string()
		for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			hm := h.as_map()
			hn := (hm['name'] or { toml.Any('') }).string()
			if !m.faults.any(it.fb == fb && it.handler == hn) {
				continue
			}
			p := u64((hm['period_ms'] or { toml.Any(0) }).i64())
			if p > longest {
				longest = p
			}
		}
	}
	// an interrupt-driven handler has no period: a floor stands in for it
	if longest < fault_grace_floor_ms {
		longest = fault_grace_floor_ms
	}
	return 2 * longest * 1000
}

// fault_grace_floor_ms: the barrier's period floor, for interrupt-driven fault-testing handlers
const fault_grace_floor_ms = u64(50)

// fault_target_cycle_boot: right after NM's init, before the loop's first pass consumes a report —
// NM may start awake (request = true), and then the operation cycle has already begun: a result the
// FBs report while the first wait blocks must land inside it, not before it.
fn fault_target_cycle_boot(m Model) []string {
	if !fault_target_on(m) || !m.nm.on || m.fault_cycle != '' {
		return []string{}
	}
	return [
		'\tg_fcycle_on = g_nm.awake() // the operation cycle follows NM from boot (D3)',
		'\tif g_fcycle_on {',
		'\t\tg_fmem.cycle_start()',
		'\t}',
	]
}

// fault_target_boot: each fault cell's byte-IOC arena, sized to its struct, before any thread runs.
fn fault_target_boot(m Model) []string {
	if !fault_target_on(m) {
		return []string{}
	}
	mut g := ['\tfcfg_rep := fault.Reports{}', '\tfcfg_ctl := fault.Control{}']
	for fb in fault_fbs(m) {
		g << '\tC.iocb_cfg(${fault_cell(m, fb, false)}, u16(sizeof(fcfg_rep))) // ${fb}: reports'
		g << '\tC.iocb_cfg(${fault_cell(m, fb, true)}, u16(sizeof(fcfg_ctl))) // ${fb}: control'
	}
	return g
}

// comm_glue_syms: every C symbol a generated image may declare from boards/common/comm_glue.c,
// the ONE generic ThreadX glue — the IOC pool, the load cells, the io execution counter, the
// FDCAN Rx wake. threadx_makefiles_test.v pins both directions: the glue defines each of these,
// and every such declaration the generator can emit is listed here.
const comm_glue_syms = ['ioc_pool_init', 'ioc_pub', 'ioc_get', 'ioc_get_ever', 'load_pub',
	'load_pub_slot', 'load_permille', 'load_100ms', 'load_1s', 'load_10s', 'load_overruns',
	'load_sum_permille', 'load_sum_100ms', 'load_sum_1s', 'load_sum_10s', 'load_sum_overruns',
	'io_exec_add', 'io_exec_us', 'comm_rx_irq_enable', 'comm_rx_irq_enable_idx', 'comm_rx_wait']

// shell_glue_syms: the shell's built-in target commands, boards/common/shell_glue.c (a node's own
// [shell] commands are its target_ext.c's)
const shell_glue_syms = ['shell_ps', 'shell_bmc']

// boot_glue_syms: the programming handoff's board side, boards/common/boot_handoff.c ([boot])
const boot_glue_syms = ['boot_handoff_request', 'boot_handoff_ok', 'boot_image_version']

// nvm_glue_syms: where the NvM journal lives, boards/common/nvm_map.c (the board's bootmap.h
// names the two sectors); the flash driver behind it is the board's own (board.mk BOARD_FLASH,
// the bootloader's driver too)
const nvm_glue_syms = ['nvm_map_a', 'nvm_map_b', 'nvm_map_size']
const flash_driver_syms = ['bflash_erase', 'bflash_program', 'bflash_read', 'bflash_blank']

// ioc_pool_n: comm_glue.c's IOC_POOL_N — the target IOC cells an image may use (pinned equal by
// threadx_makefiles_test.v; a smaller pool silently dropped every index past it, #247).
const ioc_pool_n = 16

// glue_build_lines: what a ThreadX image links for its generic glue, for gen/loom_build.mk — each
// shared glue file whose symbols the generated code declares, read off the emitted declarations
// themselves so the list and the code cannot disagree, plus comm_glue.c for DoIP, whose C seam
// (driver/eth/doip_netx.c) wakes the comm thread through comm_wake. Defined, empty when unused
// (an eth-only node keeps the weak FDCAN stubs), on every ThreadX image, and every ThreadX
// Makefile lists it (threadx_makefiles_test.v) — no Makefile names a glue file (#359).
fn glue_build_lines(glue []string, doip bool) string {
	mut declared := map[string]bool{}
	for l in glue {
		if l.starts_with('fn C.') {
			declared[l['fn C.'.len..].all_before('(')] = true
		}
	}
	mut srcs := []string{}
	if doip || comm_glue_syms.any(declared[it]) {
		srcs << r'$(REPO)/boards/common/comm_glue.c'
	}
	if shell_glue_syms.any(declared[it]) {
		srcs << r'$(REPO)/boards/common/shell_glue.c'
	}
	if boot_glue_syms.any(declared[it]) {
		srcs << r'$(REPO)/boards/common/boot_handoff.c'
	}
	if nvm_glue_syms.any(declared[it]) {
		srcs << r'$(REPO)/boards/common/nvm_map.c'
	}
	if flash_driver_syms.any(declared[it]) {
		srcs << r'$(BOARD_FLASH)'
	}
	if srcs.len == 0 {
		return 'LOOM_GLUE_SRCS :=\n'
	}
	return 'LOOM_GLUE_SRCS = ${srcs.join(' ')}\n'
}

// fault_build_lines: what the image links for its fault cells, for gen/loom_build.mk — the byte
// IOC, unless the eth thread already links it (LOOM_NET_SRCS). Defined on every ThreadX image,
// empty when unused, and every ThreadX Makefile lists it beside its BSP (pinned by
// threadx_makefiles_test.v), so adding a [[fault]] to a node needs no Makefile edit.
fn fault_build_lines(m Model) string {
	if !m.target.threadx {
		return ''
	}
	if !fault_target_on(m) || eth_thread_on(m) {
		return 'LOOM_FAULT_SRCS :=\n' // always defined: a Makefile lists it whatever the node carries
	}
	return 'LOOM_FAULT_SRCS = ' + r'$(REPO)/boards/common/iocb.c' + '\n'
}

// counter_thr reads a counter-debounce threshold wide and range-checks it BEFORE narrowing, so a
// huge value can never wrap into a valid (tiny) one.
fn counter_thr(v i64, name string, key string) int {
	k := schema_key('fault_debounce', key)
	if !k.in_range(v) {
		panic('loom2v: [[fault]] "${name}": debounce.${key} ${v} must be ${k.min}..${k.max}')
	}
	return int(v)
}

// bool_field_of checks "Signal.field" names a bool field of a declared signal — and, on a signal
// received from a bus, its VALUE field: the bridge decodes only that one, so any other field of a
// received signal reads false forever.
fn bool_field_of(m Model, ref string, what string) {
	sname := ref.all_before('.')
	field := ref.all_after('.')
	si := m.sig_of[sname] or { panic('loom2v: ${what} "${ref}" names no signal') }
	if !si.fields.any(it.name == field && it.typ == 'bool') {
		panic('loom2v: ${what} "${ref}" is not a bool field of signal ${sname}')
	}
	if si.external && si.rx && field != si.val_field {
		panic('loom2v: ${what} "${ref}": ${sname} is received from ${si.from}, which fills only its value field `${si.val_field}` — `${field}` would read false forever')
	}
}

// handler_reads: the signals the named FB handler reads, or none if there is no such handler.
fn handler_reads(doc toml.Doc, fb string, handler string) ?[]string {
	for c in ecumodel.toml_arr(doc, 'fb') {
		cm := c.as_map()
		if (cm['name'] or { toml.Any('') }).string() != fb {
			continue
		}
		for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			hm := h.as_map()
			if (hm['name'] or { toml.Any('') }).string() == handler {
				return (hm['reads'] or { toml.Any([]toml.Any{}) }).array().map(it.string())
			}
		}
	}
	return none
}

// fault_init_lines: the debouncers of `fb`'s faults, configured when the partition starts.
fn fault_init_lines(m Model, fb string) []string {
	mut out := []string{}
	for k, f in m.faults.filter(it.fb == fb) {
		out << '\tst.fdeb_${snake(fb)}[${k}] = fault.Debounce{'
		if f.time_based {
			out << '\t\ttime_based: true'
		}
		out << '\t\tfail_thr: ${f.fail_thr}'
		out << '\t\tpass_thr: ${f.pass_thr}'
		out << debounce_step_lines(f, '\t\t')
		out << '\t}'
	}
	return out
}

// debounce_step_lines: the AUTOSAR-shaped counter's non-default settings, for any debouncer init.
fn debounce_step_lines(f FaultCfg, ind string) []string {
	mut out := []string{}
	if f.inc != 1 {
		out << '${ind}inc: ${f.inc}'
	}
	if f.dec != 1 {
		out << '${ind}dec: ${f.dec}'
	}
	if f.jump {
		out << '${ind}jump: true'
	}
	return out
}

// fault_step_lines: right after `fb.handler` returns, on its thread (docs/diagnostics.md §3.3):
// apply any clear the bridge requested, debounce each fault this handler tests (under its enable
// conditions), and publish the fb's report cell. The index k is the fault's position among the FB's
// faults — the same order the bridge and the fault memory use.
fn fault_step_lines(m Model, fb string, handler string) []string {
	fbf := m.faults.filter(it.fb == fb)
	if !fbf.any(it.handler == handler) {
		return []string{}
	}
	f := snake(fb)
	mut out := []string{}
	if m.target.threadx {
		out << '\tfault_now := C.board_now_us()'
		out << '\tC.iocb_get(${fault_cell(m, fb, true)}, &st.fctl_${f}) // the generations to apply (and held flags), from the comm thread'
	} else {
		out << '\tfault_now := osal.now_us()'
		out << '\tosal.${acquire_fn('triple')}(fault_ctl_${f}_ch, &st.fctl_${f}, u8(sizeof(st.fctl_${f})))'
	}
	for k, fc in fbf {
		if fc.handler != handler {
			continue
		}
		en := if fc.enable.len == 0 {
			'true'
		} else {
			fc.enable.map('inp.${snake(it.all_before('.'))}.${it.all_after('.')}').join(' && ')
		}
		out << '\tst.fdeb_${f}[${k}].apply(st.fctl_${f}.gen[${k}], st.fctl_${f}.held[${k}])'
		out << '\tst.fdeb_${f}[${k}].step(outp.fault.${snake(fc.name)}, fault_now, ${en})'
		out << '\tst.frep_${f}.r[${k}] = st.fdeb_${f}[${k}].rep'
	}
	if m.target.threadx {
		out << '\tC.iocb_pub(${fault_cell(m, fb, false)}, &st.frep_${f}) // debounced state + counters, to the comm thread'
	} else {
		out << '\tosal.${publish_fn('triple')}(fault_rep_${f}_ch, &st.frep_${f}, u8(sizeof(st.frep_${f})))'
	}
	return out
}

// validate_signal_fault: a signal-status fault's source must be received on the diagnostic bus
// (the bridge that owns the fault memory is the detector) and must be able to show the condition:
// a timeout needs a deadline on its frame, integrity a protection check, lost the E2E counter.
fn validate_signal_fault(m Model, f FaultCfg) {
	si := m.sig_of[f.signal] or { panic('loom2v: [[fault]] "${f.name}": signal "${f.signal}" is not declared') }
	bus := m.isotp_conns[0].bus
	if !(si.external && si.rx && si.bus == bus) {
		panic('loom2v: [[fault]] "${f.name}": signal "${f.signal}" must be received on the diagnostic bus "${bus}" — its bridge is the detector')
	}
	msg := si.dbc_msg
	if !si.has_status {
		panic('loom2v: [[fault]] "${f.name}": ${f.signal} needs `status = "RxStatus"` — the bridge watches its status')
	}
	// `lost` is an EVENT: one failed result per gap, and the next good frame passes — a time
	// debounce, a counter needing several failures, or one that accumulates up from a healed
	// -pass could never qualify it
	if f.on == 'lost' && (f.time_based || f.fail_thr > 1 || !f.jump) {
		panic('loom2v: [[fault]] "${f.name}": a lost-frames fault fails once per gap — it needs a counter debounce with fail = 1 that jumps (the default for fail = 1)')
	}
	match f.on {
		'timeout' {
			if bad := m.frames.e2e_timeout_bad[msg] {
				panic('loom2v: [[fault]] "${f.name}": frame "${msg}": its E2ETimeout "${bad}" in the DBC is not a number of ms — fix it, or set e2e.timeout_ms')
			}
			if !has_deadline(m, msg, bus) {
				panic('loom2v: [[fault]] "${f.name}": frame "${msg}" has no deadline (rx.timeout_ms, e2e.timeout_ms, or E2ETimeout in the DBC) — a timeout could never be seen')
			}
		}
		'integrity' {
			if !m.frames.e2e_here(msg, bus) && !m.frames.secoc_here(msg, bus) {
				panic('loom2v: [[fault]] "${f.name}": frame "${msg}" carries no E2E or SecOC — an integrity failure could never be seen')
			}
		}
		else { // lost
			if si.lost_type == '' {
				panic('loom2v: [[fault]] "${f.name}": ${f.signal} needs a `lost` counter (an E2E-protected frame) to be watched for lost frames')
			}
		}
	}
}

// fdcan_index: the one-digit FDCAN index "0".."2" a bus name carries ("can0" -> "0"), '' when it has
// no single such digit — the driver opens a bus by that index (blob_can_open reads name[0] - '0')
fn fdcan_index(bus string) string {
	mut digits := ''
	for cc in bus {
		if cc >= `0` && cc <= `9` {
			digits += cc.ascii_str()
		}
	}
	if digits.len != 1 || digits[0] > `2` {
		return ''
	}
	return digits
}
