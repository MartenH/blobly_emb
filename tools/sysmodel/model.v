// sysmodel — the SYSTEM view over a set of nodes (docs/multi-node.md). Where
// ecumodel validates one ecu.toml, sysmodel composes many: it parses a
// `system.toml` (buses + their DBCs, nodes and which buses each sits on, node
// identities, cross-bus routes), loads each node's ecu.toml, and extracts what
// the system-level checks need — per-bus producers/consumers and each node's
// identities. The checks themselves live in checks.v; syscheck is the CLI.
//
// The extraction is deliberately thin: a `[[signal]]` whose `to` is a bus is a
// producer on that bus, whose `from` is a bus is a consumer — the same
// endpoint model the single-node generator already uses (docs/multi-node.md
// "the transport ladder"). A node's local bus name is matched to a system bus
// by that bus's `interface` (the H735's `[bus.can0]` == system `[bus.compute]`
// when compute.interface == "can0").
module sysmodel

import os
import rand
import toml
import tools.candb
import tools.ecumodel
import tools.doipcfg
import tools.cfgschema

// Bus — one CAN segment with its own contract. `name` is the system-scope key
// ([bus.compute]); `interface` is the SocketCAN/driver name a node's ecu.toml
// spells locally ("can0"); `dbc` is that segment's frame contract.
pub struct Bus {
pub mut:
	name      string
	interface string
	// kind selects the CARRIER, and with it the frame contract: a CAN bus carries frames
	// described by a `dbc`; a someip bus carries a SERVICE's events/methods, so it has a
	// service id + version instead (docs/someip.md). Default 'can' — every existing
	// [bus.*] keeps its meaning without touching a single system.toml.
	kind      string = 'can'
	fd        bool
	bitrate   int
	dbc       string
	// someip only: the service this endpoint offers. A signal on a someip bus rides an
	// EVENT of this service rather than a DBC frame; a method is a request/response.
	// has_service records PRESENCE, not a nonzero value: 0x0000 is a legal service id
	// (the per-node schema takes the full u16 range), so an omitted key is the error.
	service     u32
	has_service bool
	version     u32
	has_version bool
	// the declared values fit the WIRE widths: a SOME/IP header carries service as u16
	// and interface version as u8, so -1 / 0x10000 / 256 are not "large numbers", they
	// are impossible contracts. Recorded at parse (before the u32 cast wraps them).
	service_ok bool = true
	version_ok bool = true
	// ...and they must be INTEGERS. .i64() coerces a string to 0, which is a legal service
	// id and a legal interface version, so a type error would lower into an explicit numeric
	// 0 that the node gate cannot tell from a declared one (codex on #245 round 6).
	service_int bool = true
	version_int bool = true
	// the NM cluster on this bus (dissolution: the identity source the generator
	// stamps into each node's [nm]). peers = the alive-id range; the timings are
	// the shared sleep/wake config. 0/absent = the module defaults.
	nm_peers_lo      u32
	nm_peers_hi      u32
	has_nm_cluster   bool
	nm_msg_cycle_ms  int
	nm_timeout_ms    int
	nm_repeat_ms     int
	nm_wait_sleep_ms int
}

// Diag — a node's ISO-TP diagnostic/boot address pair (how the OTA master
// reaches this node's UDS session). 0 = unset.
pub struct Diag {
pub mut:
	req u32
	rsp u32
}

// Node — one ECU. `ecu` points at its authored ecu.toml (internals); `buses`
// names the system buses it sits on; the identities are allocated at system
// scope and cross-checked for collisions.
pub struct Node {
pub mut:
	name         string
	ecu          string // path to the node's ecu.toml, relative to system.toml
	buses        []string
	nm           u32  // NM node id allocated by system.toml (node id 0 is valid)
	has_nm_alloc bool // whether [[node]] declared `nm` at all (0 != absent)
	nm_alloc_ok  bool // whether the allocated `nm` is in loom2v's 0..255 range
	diag         Diag
	trace        int
	has_trace    bool // whether [[node]] declared `trace` (0 is a valid trace id)
	// A someip segment has no shared wire: every member answers at its OWN address, so the
	// endpoint is the NODE's identity, not the bus's (#245). `port` is where this node
	// listens; each member's peer is the other member's endpoint, which is what makes the
	// reciprocity check possible and what sysgen lowers into the node's [someip].
	endpoint     string // "192.168.0.51" — the address this node answers at
	port         u32
	port_raw     i64  // pre-narrowing, so an out-of-range port is rejected not truncated
	has_port     bool // an omitted port is diagnosed as omitted, not as a zero
	port_int     bool = true // ...and 30490.5 truncates to a legal, different port
	has_endpoint bool
	// the endpoint's subnet: its netmask and default gateway (none = absent: tools/netcfg's
	// defaults, a /24 whose .1 is the gateway), lowered beside the address; endpoint_not_str names
	// a key of the two authored as something other than a string
	endpoint_netmask ?string
	endpoint_gateway ?string
	endpoint_not_str []string
	// `doip = { logical = 0x07A0 }`: the node's diagnostic server is reachable over DoIP
	// (ISO 13400) too, at its endpoint address. Lowered into the node's [doip] — the address is
	// the endpoint's, so a node has ONE network identity and it is declared here, not per node.
	has_doip            bool
	doip_logical        u32
	doip_logical_raw    i64
	has_doip_logical    bool
	doip_logical_int    bool = true
	doip_functional     u32
	doip_functional_raw i64
	has_doip_functional bool
	doip_functional_int bool = true
	doip_unknown        []string // keys of the doip table this schema does not know (typos)
	// ...and the entity's ISO 13400-2 transport policy (tools/doipcfg), lowered one-to-one into
	// [doip] under the same names; doip_not_int names every policy key authored as anything but
	// an integer (a list: anything but a list of integers)
	doip_policy  doipcfg.Policy
	doip_not_int []string
	// --- extracted from the node's ecu.toml (filled by load_node) ---
	view NodeView
}

// IsotpConn — the node's [isotp] diagnostic connection: the local bus interface it
// rides and its on-wire rx/tx CAN ids (0 is a valid id loom2v emits as configured).
pub struct IsotpConn {
pub mut:
	iface         string
	rx_id         u32
	tx_id         u32
	functional_id u32 // 0 = none; a SHARED receive id (every server on the bus may listen)
}

// SysSignal — a cross-node signal declared ONCE at system scope (the full
// dissolution, docs/multi-node.md): its name, fields, the node that PRODUCES it,
// the bus it rides, and the AUTHORED DBC frame it maps to (no wire format is
// ever invented). The generator emits `to = <bus>` into the producer and
// `from = <bus>` into every node whose FB reads it.
pub struct SysSignal {
pub mut:
	name     string
	fields   map[string]string // field name -> type ("u16", …), the [[signal]].fields table
	producer string            // the node name that transmits it
	bus      string            // the system bus name it rides
	frame    string            // the authored DBC frame it maps to
	cycle_ms int               // the producer's tx cadence (0 = event/default)
	// PRESENCE, not value: on a someip bus any signal-level cadence is wrong (the event
	// transmits), and testing `> 0` let an explicit `cycle_ms = -1` through to be discarded
	// silently by a lowering that never emits the field (codex on #245).
	has_cycle_ms bool
}

// SysFrame — a PDU the SYSTEM owns. On a CAN bus the layout comes from the DBC, so a signal
// only names its frame; a someip bus has no DBC, so the event's id, its signal set, its tx mode
// and its E2E trailer are declared here and lowered into each member (#245).
pub struct SysFrame {
pub mut:
	name         string
	bus          string
	id           u32
	has_id       bool
	signals      []string
	tx_mode      string // 'cyclic' | 'event' | '' (unset -> the producer's default)
	cycle_ms     int
	min_delay_ms int
	// PRESENCE of the tx table and its keys: `tx = { cycle_ms = 300 }` is valid shorthand, so
	// "no mode" does not mean "no tx", and a supplied 0 is a value to reject downstream rather
	// than a key to drop.
	has_tx           bool
	// ...and `tx` must actually be a TABLE. as_map() answers an empty map for a scalar or an
	// array, so `tx = "cyclic"` sets has_tx with nothing in it and lowers as `tx = { }` — which
	// the node gate reads as its DEFAULT cyclic mode at 100 ms, a cadence nobody authored.
	tx_is_table      bool = true
	has_cycle_ms     bool
	has_min_delay_ms bool
	has_e2e      bool
	e2e_data_id  u32
	e2e_counter  int
	e2e_crc      int
	// LOWERING IS RE-SERIALIZATION: whatever this parser normalizes away is a wire contract the
	// system declared and the target never sees. So the RAW values are kept for the range
	// checks (u32() truncation turned an id of 0x100008001 into a legal-looking 0x8001), and so
	// is key PRESENCE, because a defaulted 0 is indistinguishable from a declared one once
	// written out (codex on #245).
	id_raw           i64
	id_int           bool = true
	cycle_ms_raw     i64
	min_delay_ms_raw i64
	// ...and they must be INTEGERS. .i64() drops the type AND the fraction: 300.5 becomes an
	// in-range 300, which someip_frame_lines then writes as an integer, so ecumodel's own
	// `!is i64` check sees nothing wrong and the cadence silently differs from the authored one.
	cycle_ms_int     bool = true
	min_delay_ms_int bool = true
	e2e_data_id_raw  i64
	e2e_counter_raw  i64
	e2e_crc_raw      i64
	e2e_counter_int  bool = true
	e2e_crc_int      bool = true
	// e2e.timeout_ms: the RECEIVER's sender-loss timeout (REQ-E2E-002), lowered to the receiving
	// node only — the producer's own E2E has no use for it
	has_e2e_timeout bool
	e2e_timeout_raw i64
	e2e_timeout_int bool = true
	has_e2e_data_id bool
	e2e_data_id_int bool // the authored value was actually an integer, not a coerced string
	unknown_keys    []string
}

// Route — a cross-bus forward on a gateway node. Exactly one of `frame`
// (raw-PDU, 1:1) or `signal` (decode-re-encode across differing DBCs) is set.
pub struct Route {
pub mut:
	gateway string
	frame   string
	signal  string
	from    string // source bus name
	to      string // dest bus name
}

// NodeView — the system-relevant slice of a node's ecu.toml: what it produces
// and consumes on each bus (by the node's LOCAL bus interface name), plus its
// NM cluster range. Keyed by the node's local bus name (== a system bus
// interface).
pub struct NodeView {
pub mut:
	// interface -> signal names the node transmits on / receives from that bus
	produces map[string][]string
	consumes map[string][]string
	// interface -> frame names the node transmits on that bus (for frame routes
	// / frame-level single-writer)
	tx_frames   map[string][]string
	nm_node     u32  // the node's own [nm] node id (checked against system.toml's)
	has_nm_node bool // whether [nm].node was declared (node id 0 is valid, 0..255)
	nm_node_ok  bool // whether [nm].node is in loom2v's 0..255 range
	alive       u32  // the node's [nm] alive id (the on-wire id, within peers)
	has_alive   bool // whether [nm].alive was declared (alive = 0 is a valid CAN id)
	// alive resolved from a NAMED DBC binding (a DBC message deliberately IS the
	// alive frame). Only THEN is that message exempt from the application-frame-in-
	// NM-range check — a numeric alive id does not make a same-id app frame legal.
	alive_from_binding bool
	peers_lo           u32
	peers_hi           u32
	has_nm             bool   // an [nm] table is present
	nm_enabled         bool   // [nm].enabled (default true) — false = a non-participant node
	nm_bus             string // the bus this node runs NM on (nm.bus, else the telemetry bus)
	alive_binding      string // [nm].alive when it is a DBC message NAME (not a numeric id)
	is_threadx         bool   // [target].kind == "threadx" (loom2v generates NM only then)
	is_baremetal       bool   // [target].kind == "baremetal" (loom2v rejects bus signals there)
	// loom2v emits the comm thread (and, only inside it, the NM state machine, the
	// threadx trace module, and the shell) when the threadx target has a BRIDGE —
	// >=1 external bus signal or an ISO-TP connection (comm_thread_on). A bridgeless
	// threadx node builds WITHOUT any of those frames on the wire.
	comm_thread_on bool
	has_telemetry  bool   // a [telemetry] block with a bus (loom2v requires it for threadx)
	telem_bus      string // [telemetry].bus resolved to its interface
	// [someip] — the node's SOME/IP ENDPOINT: `bus` names one of its local [bus.*]
	// tables (whose interface is this node's OWN address) and service/version are the
	// contract it offers on it. A someip system bus is joined by NAMING it (explicit
	// membership, see check_someip_membership), so this endpoint is what that claim
	// resolves to — the local side of a bus whose interface deliberately differs.
	has_someip     bool
	someip_iface   string // [someip].bus resolved to its interface (this node's address)
	someip_service u32
	someip_version u32
	// the STATIC peer this endpoint talks to: the generated bridge sends only TO it and
	// accepts only FROM it (there is no service discovery), so two members of a bus are
	// connected only if they point at each other — a shared bus name does not connect them.
	someip_peer string // [someip].peer, "<address>:<port>"
	someip_port int    // [someip].port — the port THIS endpoint listens on
	has_doip    bool   // an authored [doip] — the system owns it in the dissolution model
	// the node's [uds] as the network-reachability rule reads it (doipcfg.service_refusals /
	// bench_key_refusal): a `services` table declared, its rows, and the 0x27 key it names
	uds_table        bool
	uds_rows         []doipcfg.ServiceRow
	did_writes       []doipcfg.DidWrite // [[did]] write sides, for REQ-NET-012 at the system gate
	uds_security_key string
	// [boot] (the programming handoff) and its "0x10 02" row's level, for the same rule
	boot                 bool
	uds_handoff_security i64
	// an authored eth [[frame]] naming its OWN `peer`: the composed model checks reciprocity on
	// [someip].peer alone, so a per-event peer is the dissolution's to lower, not a node's to author
	frame_peer bool
	// the bus [shell] rides (a LOCAL key, "eth0" for an RPC shell on a someip member) — its own, or
	// [telemetry].bus inherited, by ecumodel.module_bus, the rule loom2v emits it by
	shell_bus string
	// the on-wire id each signal rides, keyed "<iface>|<signal>". On a someip endpoint
	// that id IS the EVENT the receive bridge dispatches on, so two members can agree on
	// a signal NAME and still never talk (docs/someip.md).
	sig_frame_id map[string]u32
	// the PAYLOAD contract each signal rides, same key. The generator derives the wire
	// layout from these inputs, so two ends that agree on them derive the SAME layout —
	// comparing the inputs is exact without duplicating the packing rules here.
	//   sig_fields:  the signal's fields, "name:type,..." SORTED BY NAME (the order the
	//                generator packs them in — TOML table order is not data)
	//   sig_payload: the frame's own contract — its signal list (order = packing order)
	//                and E2E parameters. The frame NAME is deliberately excluded: it is
	//                node-local, and two peers may spell it differently on one wire.
	sig_fields  map[string]string
	sig_payload map[string]string
	// the telemetry frames the threadx comm thread transmits on the telemetry bus
	// (CpuLoad + its detail). REAL tx ids: unique across nodes, not colliding with
	// an application frame or the NM range (REQ-TOPO-002). CpuLoad is always sent
	// (effective id, 0 if omitted); the detail only when detail_id != 0.
	telem_id        u32
	telem_detail_id u32
	// per local-bus-interface FD flag: loom2v's threadx FDCAN backend is
	// classic-only, so a threadx node on an fd = true telemetry bus can't build.
	local_bus_fd map[string]bool
	// [trace]: a threadx node streams the raw exec-hook trace as ONE frame per
	// record (record_id, default 0x7e5) on the telemetry channel — a REAL tx frame
	// that must not collide with telemetry/application/NM ids (REQ-TOPO-002). (The
	// cmd/rsp/dump_fc protocol is host-only, not emitted on the threadx target.)
	trace_on          bool
	trace_bus         string // [trace].bus resolved to its interface (else the telemetry bus)
	trace_level       string // [trace].level (parse_trace's default "thread+fb")
	trace_push_ms_set bool   // [trace].push_ms present (the bare-metal superloop refuses it)
	trace_record_id   u32
	trace_record_name string // a DBC message NAME binding (resolved against the bus DBC)
	trace_rsp_id      u32    // the TraceModule also transmits command RESPONSES (default 0x7e3)
	trace_rsp_name    string
	// trace RECEIVE endpoints: the module reacts to cmd (0x7e2) and dump_fc (0x7e6),
	// so another node transmitting at those ids would drive its trace state. These
	// ids are RESERVED on the trace bus (a tx frame colliding with them is a bug).
	trace_cmd_id        u32
	trace_cmd_name      string
	trace_dump_fc_id    u32
	trace_dump_fc_name  string
	trace_dump_fc_bound bool // dump_fc reserves a RX id ONLY when explicitly bound
	// [isotp] diagnostic connection: their rx_id/tx_id are on-wire diagnostic CAN
	// ids (0 is valid — loom2v emits them as configured), reserved on the isotp bus.
	has_isotp   bool
	isotp_conns []IsotpConn
	// [shell]: a threadx node transmits shell.out responses (default 0x7f1) on the
	// comm channel — a REAL tx frame that must not collide with other bus ids.
	shell_on       bool
	shell_out_id   u32
	shell_out_name string // a DBC message NAME binding (resolved against the bus DBC)
	// shell RECEIVE endpoints: command lines on shell.in (default 0x7f0) and ISO-TP
	// flow control on shell.fc (default 0x7f2) — RESERVED rx ids on the comm bus.
	shell_in_id   u32
	shell_in_name string
	shell_fc_id   u32
	shell_fc_name string
	// number of [[partition]] blocks: loom2v generates the host trace module only
	// for the SINGLE-partition host shape (trace_host), so a multi-partition host
	// node emits no trace frames.
	partition_count int
	// a node-local [[route]]: loom2v's trace_host also requires routes.len == 0, so
	// a routed host node builds WITHOUT trace (its trace frames are not on the wire).
	has_route bool
	// NM timing presence: loom2v applies its default only when the KEY is ABSENT,
	// so an explicit 0 must be preserved (not normalized to the default).
	nm_has_msg_cycle  bool
	nm_has_timeout    bool
	nm_has_repeat     bool
	nm_has_wait_sleep bool
	// the node's FULL per-node gate result (tools/ecucheck: unknown keys, wrong
	// types, structural rules) — a system can't be clean if a node can't build.
	config_errors []string
	// NM sleep/wake timing (0 = defaulted/unset). The cluster must agree on
	// these or its state machines transition at incompatible times (REQ-TOPO-004).
	nm_msg_cycle_ms  int
	nm_timeout_ms    int
	nm_repeat_ms     int
	nm_wait_sleep_ms int
	local_buses      []string // the [bus.X] names declared in the node's ecu.toml
	// --- DISSOLUTION model (docs/multi-node.md P1b): a partial node authors only
	// its internals; the generator derives wiring from these + system.toml. ---
	// FB intent: the signal names this node's handlers read / write, by name.
	fb_reads  []string
	fb_writes []string
	// signal name -> the distinct partitions whose FBs read it (a cross-node RX
	// signal read from >1 partition = concurrent readers of one SPSC IOC channel).
	read_partitions map[string][]string
	// a dissolved partial is INTERNALS-ONLY for BUS wiring: it must declare no
	// bus-endpoint [[signal]], no [[frame]], no [[route]] (the system owns those).
	// NODE-LOCAL signals — an io point or a node-internal cross-partition signal,
	// whose endpoints are "io" or the node's own partitions, never a bus — ARE the
	// node's application and stay authored (docs/multi-node.md: a gpio/adc/pwm node).
	authored_signals bool     // a [[signal]] with a BUS endpoint (forbidden)
	local_signals    []string // node-local signal names (io / cross-partition) — allowed
	params           []string // [[param]] names: node-local INPUTS an FB reads (docs/diagnostics.md §3.4)
	authored_frames  bool
	authored_routes  bool
}

// System — the whole parsed system.toml plus each node's loaded view.
pub struct System {
pub mut:
	buses        []Bus
	nodes        []Node
	signals      []SysSignal // cross-node signals declared at system scope (dissolution)
	frames       []SysFrame  // system-owned PDUs — someip events, whose layout has no DBC
	routes       []Route
	unknown_keys []string // top-level sections that aren't part of the schema (typos)
	// keys of a [bus.*], [bus.*.nm], [[signal]], [[node]] (endpoint, diag) or [[route]] that the
	// schema does not name, each as `<where>: unknown key "<k>" (allowed: …)` — a typo there was
	// read as the key's absence (a `producr` meant no producer, an `interfce` no channel)
	unknown_nested []string
	dir          string   // directory of system.toml (node/dbc paths resolve against it)
}

// signal_by_name returns the system signal with the given name, or none.
pub fn (s System) signal_by_name(name string) ?SysSignal {
	for sig in s.signals {
		if sig.name == name {
			return sig
		}
	}
	return none
}

fn m_str(m map[string]toml.Any, key string) string {
	return (m[key] or { toml.Any('') }).string()
}

fn m_int(m map[string]toml.Any, key string) int {
	return int((m[key] or { toml.Any(0) }).int())
}

fn m_u32(m map[string]toml.Any, key string) u32 {
	return u32((m[key] or { toml.Any(0) }).int())
}

// as_top_array: a top-level `[[section]]`'s entries, refusing the single-bracket form.
//
// `.array()` answers an EMPTY array for anything that is not one, so `[frame]` written instead
// of `[[frame]]` silently discards the whole section — and if the rest of the system is composed,
// syscheck then reports OK on a system whose event contract was never checked. `[signal]` would
// drop every signal the same way. This repo has already lost a requirement to the identical trap
// ([[requirement]] vs [[req]], silently ignored until the count was noticed), so it is refused
// here rather than tolerated (codex on #279).
fn as_top_array(v toml.Any, key string) ![]toml.Any {
	if v !is []toml.Any {
		return error('`${key}` must be written as [[${key}]] (an array of tables) — a single [${key}] table is silently ignored, so every entry in it would vanish')
	}
	return v.array()
}

// m_is_int: was this key authored as an INTEGER?
//
// Every narrowing helper above destroys evidence. `.int()`/`.i64()` truncate a float and coerce
// a string, and what comes out is always a LEGAL value of the field — 300.5 becomes a valid
// cadence, "wrong" becomes the valid identity 0, 32769.5 becomes the valid event id 0x8001. The
// lowering then re-serialises that as an integer, so the node gate's own `!is i64` check sees
// nothing wrong: the evidence only exists HERE. An absent key is not an error of this kind, so
// it answers true and presence is tracked separately.
//
// Adding a numeric field without calling this is the recurring defect on #245: it took three
// review rounds and nine fields, one at a time. someip_test.v'"'"'s comptime test over SysFrame is
// the guard — a new `*_raw` field with no `*_int` sibling fails the build.
fn m_is_int(m map[string]toml.Any, key string) bool {
	v := m[key] or { return true }
	return v is i64
}

fn m_bool(m map[string]toml.Any, key string) bool {
	return (m[key] or { toml.Any(false) }).bool()
}

// binding_id reads a comm-module endpoint binding (trace record/rsp, shell out):
// a numeric CAN id, a DBC message NAME (resolved later against the bus DBC), or
// absent (the module default). Returns (id, name) — name empty unless a binding.
fn binding_id(m map[string]toml.Any, key string, def u32) (u32, string) {
	if v := m[key] {
		if v is string {
			return def, v
		}
		return u32(v.int()), ''
	}
	return def, ''
}

// snake mirrors loom2v's snake() (tools/loom2v/gen.v): CamelCase -> snake_case, so
// a named endpoint binding resolves the same way the generator does (record =
// "trace_record" matches a DBC message "TraceRecord").
fn snake(name string) string {
	return ecumodel.snake_name(name) // THE rule: generators must agree byte-for-byte
}

// parse_system reads a system.toml into a System (nodes not yet loaded — call
// load_nodes for that). Returns an error only on a malformed/absent file; a
// structurally-wrong-but-parseable system is caught by the checks, not here.
pub fn parse_system(path string) !System {
	doc := toml.parse_file(path) or { return error('sysmodel: parse ${path}: ${err}') }
	mut sys := System{
		dir: os.dir(path)
	}
	// flag unknown top-level sections (a misspelled [[nodes]] would otherwise
	// parse to zero nodes and pass silently). `signal` is the dissolution's
	// system-scope signal section (forward-compatible with the composed model).
	// 'frame' is the system-owned PDU section: a someip event's id, signal set, tx mode and
	// E2E trailer, which have no DBC to come from (#245).
	sys.unknown_keys = cfgschema.system.unknown(doc.to_any().as_map(), 'sys_top')
	// [bus.<name>] — a table of tables keyed by name
	if bv := doc.value_opt('bus') {
		for name, cfg in bv.as_map() {
			m := cfg.as_map()
			sys.note_unknown(m, 'sys_bus', 'bus "${name}"')
			kind := if k := m['kind'] { k.string() } else { 'can' }
			svc_raw := if v := m['service'] { v.i64() } else { i64(0) }
			ver_raw := if v := m['version'] { v.i64() } else { i64(0) }
			mut bus := Bus{
				name:      name
				interface: m_str(m, 'interface')
				kind:      if kind == '' { 'can' } else { kind }
				fd:        m_bool(m, 'fd')
				bitrate:   m_int(m, 'bitrate')
				dbc:       m_str(m, 'dbc')
				service:     u32(m_int(m, 'service'))
				has_service: 'service' in m
				service_ok:  cfgschema.system.key('sys_bus', 'service').in_range(svc_raw)
				service_int: m_is_int(m, 'service')
				version:     u32(m_int(m, 'version'))
				has_version: 'version' in m
				version_ok:  cfgschema.system.key('sys_bus', 'version').in_range(ver_raw)
				version_int: m_is_int(m, 'version')
			}
			// [bus.<name>.nm] — the dissolution NM cluster (peers range + timings)
			if nmv := m['nm'] {
				nm := nmv.as_map()
				sys.note_unknown(nm, 'sys_bus_nm', 'bus "${name}" nm')
				bus.has_nm_cluster = true
				bus.nm_msg_cycle_ms = m_int(nm, 'msg_cycle_ms')
				bus.nm_timeout_ms = m_int(nm, 'timeout_ms')
				bus.nm_repeat_ms = m_int(nm, 'repeat_ms')
				bus.nm_wait_sleep_ms = m_int(nm, 'wait_sleep_ms')
				peers := (nm['peers'] or { toml.Any([]toml.Any{}) }).array()
				if peers.len == 2 {
					bus.nm_peers_lo = u32(peers[0].int())
					bus.nm_peers_hi = u32(peers[1].int())
				}
			}
			sys.buses << bus
		}
	}
	// [[signal]] — cross-node signals declared once at system scope (dissolution)
	if sv := doc.value_opt('signal') {
		for sg in as_top_array(sv, 'signal')! {
			m := sg.as_map()
			sys.note_unknown(m, 'sys_signal', 'signal "${m_str(m, 'name')}"')
			mut sig := SysSignal{
				name:     m_str(m, 'name')
				producer: m_str(m, 'producer')
				bus:      m_str(m, 'bus')
				frame:    m_str(m, 'frame')
				cycle_ms:     m_int(m, 'cycle_ms')
				has_cycle_ms: 'cycle_ms' in m
			}
			if fm := m['fields'] {
				for fname, ftype in fm.as_map() {
					sig.fields[fname] = ftype.string()
				}
			}
			sys.signals << sig
		}
	}
	// [[node]]
	if nv := doc.value_opt('node') {
		for n in as_top_array(nv, 'node')! {
			m := n.as_map()
			where := 'node "${m_str(m, 'name')}"'
			sys.note_unknown(m, 'sys_node', where)
			nm_raw := (m['nm'] or { toml.Any(0) }).int() // signed, to range-check
			mut node := Node{
				name:         m_str(m, 'name')
				ecu:          m_str(m, 'ecu')
				nm:           u32(nm_raw)
				has_nm_alloc: 'nm' in m
				has_trace:    'trace' in m
				nm_alloc_ok:  cfgschema.system.key('sys_node', 'nm').in_range(nm_raw)
				trace:        m_int(m, 'trace')
			}
			if ev := m['endpoint'] {
				em := ev.as_map()
				sys.note_unknown(em, 'sys_endpoint', '${where} endpoint')
				node.endpoint = m_str(em, 'address')
				node.port = m_u32(em, 'port')
				node.port_raw = (em['port'] or { toml.Any(0) }).i64()
				node.has_port = 'port' in em
				node.port_int = m_is_int(em, 'port')
				node.has_endpoint = true
				for key in ['netmask', 'gateway'] {
					if v := em[key] {
						if v !is string {
							node.endpoint_not_str << key
						} else if key == 'netmask' {
							node.endpoint_netmask = v.string()
						} else {
							node.endpoint_gateway = v.string()
						}
					}
				}
			}
			if dv := m['doip'] {
				dm := dv.as_map()
				node.has_doip = true
				node.has_doip_logical = 'logical' in dm
				node.doip_logical = m_u32(dm, 'logical')
				node.doip_logical_raw = (dm['logical'] or { toml.Any(0) }).i64()
				node.doip_logical_int = m_is_int(dm, 'logical')
				node.has_doip_functional = 'functional' in dm
				node.doip_functional = m_u32(dm, 'functional')
				node.doip_functional_raw = (dm['functional'] or { toml.Any(0) }).i64()
				node.doip_functional_int = m_is_int(dm, 'functional')
				node.doip_policy, node.doip_not_int = doipcfg.parse(dm)
				node.doip_unknown = cfgschema.system.unknown(dm, 'sys_doip')
			}
			for b in (m['buses'] or { toml.Any([]toml.Any{}) }).array() {
				node.buses << b.string()
			}
			if dm := m['diag'] {
				d := dm.as_map()
				sys.note_unknown(d, 'sys_diag', '${where} diag')
				node.diag = Diag{
					req: m_u32(d, 'req')
					rsp: m_u32(d, 'rsp')
				}
			}
			sys.nodes << node
		}
	}
	// [[route]]
	if fv := doc.value_opt('frame') {
		for f in as_top_array(fv, 'frame')! {
			m := f.as_map()
			mut fr := SysFrame{
				name:   m_str(m, 'name')
				bus:    m_str(m, 'bus')
				id:     m_u32(m, 'id')
				id_raw: (m['id'] or { toml.Any(0) }).i64()
				id_int: m_is_int(m, 'id')
				has_id: 'id' in m
			}
			// A typo is DISCARDED by a parser that copies only what it recognises — `e2ee`
			// would silently mean "no E2E", and the generated file no longer carries the
			// misspelling for ecucheck to reject. Record them instead.
			fr.unknown_keys << cfgschema.system.unknown(m, 'sys_frame')
			if tv := m['tx'] {
				fr.unknown_keys << cfgschema.system.unknown(tv.as_map(), 'sys_frame_tx').map('tx.${it}')
			}
			if ev := m['e2e'] {
				fr.unknown_keys << cfgschema.system.unknown(ev.as_map(), 'sys_frame_e2e').map('e2e.${it}')
			}
			for sg in (m['signals'] or { toml.Any([]toml.Any{}) }).array() {
				fr.signals << sg.string()
			}
			if tv := m['tx'] {
				tm := tv.as_map()
				fr.has_tx = true
				fr.tx_is_table = tv is map[string]toml.Any
				fr.tx_mode = m_str(tm, 'mode')
				fr.cycle_ms = m_int(tm, 'cycle_ms')
				fr.min_delay_ms = m_int(tm, 'min_delay_ms')
				fr.has_cycle_ms = 'cycle_ms' in tm
				fr.has_min_delay_ms = 'min_delay_ms' in tm
				fr.cycle_ms_raw = (tm['cycle_ms'] or { toml.Any(0) }).i64()
				fr.min_delay_ms_raw = (tm['min_delay_ms'] or { toml.Any(0) }).i64()
				fr.cycle_ms_int = m_is_int(tm, 'cycle_ms')
				fr.min_delay_ms_int = m_is_int(tm, 'min_delay_ms')
			}
			if ev := m['e2e'] {
				em := ev.as_map()
				fr.has_e2e = true
				fr.e2e_data_id = m_u32(em, 'data_id')
				fr.e2e_data_id_raw = (em['data_id'] or { toml.Any(0) }).i64()
				fr.has_e2e_data_id = 'data_id' in em
				fr.e2e_data_id_int = m_is_int(em, 'data_id')
				fr.e2e_counter = m_int(em, 'counter_pos')
				fr.e2e_crc = m_int(em, 'crc_pos')
				fr.e2e_counter_int = m_is_int(em, 'counter_pos')
				fr.e2e_crc_int = m_is_int(em, 'crc_pos')
				fr.e2e_counter_raw = (em['counter_pos'] or { toml.Any(0) }).i64()
				fr.e2e_crc_raw = (em['crc_pos'] or { toml.Any(0) }).i64()
				fr.has_e2e_timeout = 'timeout_ms' in em
				fr.e2e_timeout_raw = (em['timeout_ms'] or { toml.Any(0) }).i64()
				fr.e2e_timeout_int = !fr.has_e2e_timeout || m_is_int(em, 'timeout_ms')
			}
			sys.frames << fr
		}
	}
	if rv := doc.value_opt('route') {
		for r in as_top_array(rv, 'route')! {
			m := r.as_map()
			sys.note_unknown(m, 'sys_route', 'route')
			sys.routes << Route{
				gateway: m_str(m, 'gateway')
				frame:   m_str(m, 'frame')
				signal:  m_str(m, 'signal')
				from:    m_str(m, 'from')
				to:      m_str(m, 'to')
			}
		}
	}
	return sys
}

// note_unknown records every key of `m` that the schema's table `ctx` does not name
fn (mut s System) note_unknown(m map[string]toml.Any, ctx string, where string) {
	names := cfgschema.system.table(ctx).names()
	for k in cfgschema.system.unknown(m, ctx) {
		s.unknown_nested << '${where}: unknown key "${k}" (allowed: ${names.join(', ')})'
	}
}

// bus_by_name returns the Bus with the given system name, or none.
pub fn (s System) bus_by_name(name string) ?Bus {
	for b in s.buses {
		if b.name == name {
			return b
		}
	}
	return none
}

// bus_by_interface returns the Bus with the given interface (== a node's local
// bus name), or none. Interfaces are unique (check_topology_wellformed enforces
// it) so the first match is unambiguous.
pub fn (s System) bus_by_interface(iface string) ?Bus {
	for b in s.buses {
		if b.interface == iface {
			return b
		}
	}
	return none
}

// load_nodes fills each node's NodeView from its ecu.toml. Returns the list of
// nodes it could NOT load (missing/malformed ecu.toml) as error strings, so the
// caller reports them without aborting the rest of the system view.
pub fn (mut s System) load_nodes() []string {
	mut errs := []string{}
	mut dbc_cache := map[string]candb.Database{}
	for i in 0 .. s.nodes.len {
		// node paths resolve against system.toml's dir, unless already absolute
		path := if os.is_abs_path(s.nodes[i].ecu) {
			s.nodes[i].ecu
		} else {
			os.join_path(s.dir, s.nodes[i].ecu)
		}
		view := load_node(path) or {
			errs << 'node "${s.nodes[i].name}": ${err}'
			continue
		}
		s.nodes[i].view = view
		// resolve a NAMED [nm].alive binding to its numeric on-wire id via the
		// node's NM-bus DBC, so it flows through the SAME numeric alive-uniqueness
		// check — a name and a literal that hit the same CAN id are a collision the
		// separate name/number maps would miss (REQ-TOPO-002). On success the
		// binding is cleared; if it can't be resolved it stays for the name-level
		// fallback check (two nodes naming the same message collide even undecoded).
		// Only for an ACTIVE NM node: loom2v's parse_nm returns early for enabled =
		// false (and a non-threadx node emits no NM), so an inactive [nm] has no live
		// alive id to resolve — requiring a DBC there would reject a buildable node.
		if s.nodes[i].view.alive_binding != '' && s.nodes[i].view.nm_enabled {
			name := s.nodes[i].view.alive_binding
			// a named alive binding MUST resolve to a numeric CAN id (loom2v does),
			// or its collision + in-range checks are silently skipped. An NM bus with
			// no DBC (or no matching system bus) cannot resolve it — that is a config
			// error, not a clean fall-through (REQ-TOPO-004).
			b := s.bus_by_interface(s.nodes[i].view.nm_bus) or {
				errs << 'node "${s.nodes[i].name}": [nm].alive names "${name}" but its NM bus "${s.nodes[i].view.nm_bus}" maps to no system bus with a DBC to resolve it'
				continue
			}
			if b.dbc == '' {
				errs << 'node "${s.nodes[i].name}": [nm].alive names "${name}" but its NM bus "${b.name}" has no `dbc` to resolve the name to a CAN id'
				continue
			}
			dpath := if os.is_abs_path(b.dbc) { b.dbc } else { os.join_path(s.dir, b.dbc) }
			db := dbc_cache[dpath] or {
				loaded := candb.load_dbc_file(dpath) or {
					errs << 'node "${s.nodes[i].name}": cannot load DBC "${b.dbc}" to resolve [nm].alive "${name}": ${err}'
					continue
				}
				dbc_cache[dpath] = loaded
				loaded
			}
			mut hit := false
			for msg in db.messages {
				// loom2v resolves endpoint names snake-normalized (snake(m.name) == key),
				// so alive = "alive_msg" matches a DBC message "AliveMsg".
				if snake(msg.name) == snake(name) {
					s.nodes[i].view.alive = msg.id
					s.nodes[i].view.has_alive = true
					s.nodes[i].view.alive_from_binding = true
					s.nodes[i].view.alive_binding = ''
					hit = true
					break
				}
			}
			if !hit {
				errs << 'node "${s.nodes[i].name}": [nm].alive names "${name}" but DBC "${b.dbc}" has no such message'
			}
		}
	}
	return errs
}

// load_nodes_partial fills each node's view with the PURE parse (parse_node_view,
// NO ecucheck) — the DISSOLUTION path: a partial node can't pass ecucheck alone
// (the gate moves to the GENERATED output, in sysgen).
pub fn (mut s System) load_nodes_partial() []string {
	mut errs := []string{}
	for i in 0 .. s.nodes.len {
		path := if os.is_abs_path(s.nodes[i].ecu) {
			s.nodes[i].ecu
		} else {
			os.join_path(s.dir, s.nodes[i].ecu)
		}
		doc := toml.parse_file(path) or {
			errs << 'node "${s.nodes[i].name}": parse ${path}: ${err}'
			continue
		}
		s.nodes[i].view = parse_node_view(doc)
	}
	return errs
}

// load_node parses a node's ecu.toml and extracts its NodeView.
pub fn load_node(path string) !NodeView {
	doc := toml.parse_file(path) or { return error('parse ${path}: ${err}') }
	mut v := parse_node_view(doc)
	// the node must ALSO pass the FULL per-node gate — not just the structural
	// rules but unknown keys, wrong types, and the nested-comment trap. Run the
	// REAL ecucheck (the exact gate loom2v builds behind) and surface its errors:
	// a clean system must imply buildable nodes (REQ-TOPO-005).
	v.config_errors = ecucheck_errors(path)
	return v
}

// parse_node_view extracts the system-relevant slice of a node's ecu.toml — the
// PURE parse with NO external gate. load_node adds the ecucheck; the DISSOLUTION
// generator (tools/sysgen) runs this directly on a partial node's internals.
pub fn parse_node_view(doc toml.Doc) NodeView {
	mut v := NodeView{}
	// [bus.<name>] — the node's local bus tables. The table KEY is the node's
	// LOGICAL name (used by signal from/to); its `interface` field is the PLATFORM
	// binding (the physical channel). A node is matched to a system bus by
	// INTERFACE, not by the logical key — so produces/consumes/tx_frames + the
	// local-bus set are keyed by the resolved interface (else `[bus.can0]
	// interface = "can1"` would be credited to the wrong system bus).
	mut key_iface := map[string]string{} // logical name -> interface
	if bv := doc.value_opt('bus') {
		for name, cfg in bv.as_map() {
			cm := cfg.as_map()
			iface := m_str(cm, 'interface')
			resolved := if iface != '' { iface } else { name }
			key_iface[name] = resolved
			v.local_buses << resolved
			v.local_bus_fd[resolved] = m_bool(cm, 'fd')
		}
	}
	iface_of := fn [key_iface] (logical string) ?string {
		return key_iface[logical] or { none }
	}
	// host trace generation counts FB-BEARING partitions, not raw [[partition]]
	// blocks: loom2v's m.part.by_part is populated only while assigning FBs, so a
	// partition whose threads host no FB is not counted (trace_host = 1 FB-partition).
	mut fb_threads := map[string]bool{}
	if fv := doc.value_opt('fb') {
		for f in fv.array() {
			fb_threads[m_str(f.as_map(), 'thread')] = true
		}
	}
	if pv := doc.value_opt('partition') {
		for p in pv.array() {
			pm := p.as_map()
			if tv := pm['thread'] {
				for t in tv.array() {
					if fb_threads[m_str(t.as_map(), 'name')] {
						v.partition_count++
						break // this partition hosts >=1 FB — count it once
					}
				}
			}
		}
	}
	// a NON-EMPTY node-local [[route]] disables host trace generation (loom2v
	// trace_host uses m.routes.len > 0 — an empty `route = []` still emits trace).
	if rv := doc.value_opt('route') {
		v.has_route = rv.array().len > 0
	}
	// --- DISSOLUTION (partial node): authored-section flags + FB signal intent.
	// A dissolved partial is internals-ONLY, so ANY [[signal]]/[[frame]]/[[route]]
	// is authored wiring the system should own (flagged by check_partial_no_wiring).
	// classify each [[signal]]: a NODE-LOCAL signal (io point, or a node-internal
	// cross-partition signal — BOTH endpoints are "io" or one of this node's own
	// partitions, never a bus) is the node's application and stays authored; a
	// signal with a BUS endpoint is wiring the system owns (flagged). REQ-TOPO-005.
	mut part_names := map[string]bool{}
	for p in (doc.value_opt('partition') or { toml.Any([]toml.Any{}) }).array() {
		part_names[m_str(p.as_map(), 'name')] = true
	}
	local_ep := fn [part_names] (e string) bool {
		return e == 'io' || e in part_names
	}
	for s in (doc.value_opt('signal') or { toml.Any([]toml.Any{}) }).array() {
		m := s.as_map()
		nm := m_str(m, 'name')
		if nm == '' {
			continue
		}
		if local_ep(m_str(m, 'from')) && local_ep(m_str(m, 'to')) {
			v.local_signals << nm
		} else {
			v.authored_signals = true // a bus endpoint = authored bus wiring
		}
	}
	for pv in (doc.value_opt('param') or { toml.Any([]toml.Any{}) }).array() {
		if nm := pv.as_map()['name'] {
			v.params << nm.string()
		}
	}
	if fv := doc.value_opt('frame') {
		v.authored_frames = true
		if fv is []toml.Any {
			for f in fv {
				if 'peer' in f.as_map() {
					v.frame_peer = true
				}
			}
		}
	}
	v.authored_routes = v.has_route
	// [[fb]] handlers' reads/writes = the node's signal intent, attributed to the
	// partition hosting each FB (thread -> partition). The generator derives the
	// tx/rx wiring from these + each SysSignal's producer.
	mut thread_part := map[string]string{}
	for p in (doc.value_opt('partition') or { toml.Any([]toml.Any{}) }).array() {
		pm := p.as_map()
		pname := m_str(pm, 'name')
		for t in (pm['thread'] or { toml.Any([]toml.Any{}) }).array() {
			thread_part[m_str(t.as_map(), 'name')] = pname
		}
	}
	if fbv := doc.value_opt('fb') {
		for fb in fbv.array() {
			fm := fb.as_map()
			part := thread_part[m_str(fm, 'thread')] or { '' }
			for h in (fm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hm := h.as_map()
				for r in (hm['reads'] or { toml.Any([]toml.Any{}) }).array() {
					name := r.string()
					v.fb_reads << name
					if part != '' && part !in v.read_partitions[name] {
						v.read_partitions[name] << part
					}
				}
				for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
					v.fb_writes << w.string()
				}
			}
		}
	}
	// [[signal]] from/to a bus = consume/produce on that bus (keyed by interface)
	if sv := doc.value_opt('signal') {
		for s in sv.array() {
			m := s.as_map()
			name := m_str(m, 'name')
			from := m_str(m, 'from')
			to := m_str(m, 'to')
			if name == '' {
				continue
			}
			// the signal's fields — half of the payload contract two ends of a someip
			// event must share (the frame supplies the other half). Sorted BY NAME, as
			// ecumodel.eth_layouts does when it derives the wire layout: TOML table order
			// is not data, so two nodes listing the same fields in different order build
			// the identical wire and must not be reported as a mismatch.
			mut fields := []string{}
			if fv2 := m['fields'] {
				mut fnames := fv2.as_map().keys()
				fnames.sort()
				fm2 := fv2.as_map()
				received := iface_of(from) != none
				for fname in fnames {
					ftype := (fm2[fname] or { toml.Any('') }).string()
					// a receiver's RxStatus and `lost` count are the bridge's, never on the wire:
					// the producer has neither, and counting them would read every protected
					// receiver as a mismatch
					if ftype == 'RxStatus' || (received && fname == 'lost') {
						continue
					}
					fields << '${fname}:${ftype}'
				}
			}
			flat := fields.join(',')
			if iface := iface_of(to) {
				v.produces[iface] << name
				v.sig_fields['${iface}|${name}'] = flat
			}
			if iface := iface_of(from) {
				v.consumes[iface] << name
				v.sig_fields['${iface}|${name}'] = flat
			}
		}
	}
	// [[frame]] with a tx spec = this node transmits that frame on bus
	if fv := doc.value_opt('frame') {
		for f in fv.array() {
			m := f.as_map()
			name := m_str(m, 'name')
			bus := m_str(m, 'bus')
			if name != '' && 'tx' in m {
				if iface := iface_of(bus) {
					v.tx_frames[iface] << name
				}
			}
			// the id each signal in the frame rides. A RECEIVE frame binds it just as
			// much as a transmit one (it is what the bridge dispatches on), so this is
			// recorded regardless of `tx` — on a someip endpoint it is the EVENT id.
			if name != '' && 'id' in m {
				if iface := iface_of(bus) {
					fid := m_u32(m, 'id')
					if sv := m['signals'] {
						mut sigs := []string{}
						for sg in sv.array() {
							sigs << sg.string()
						}
						mut e2e := 'none'
						if ev := m['e2e'] {
							em := ev.as_map()
							e2e = 'data_id=${m_u32(em, 'data_id')},ctr=${m_int(em, 'counter_pos')},crc=${m_int(em,
								'crc_pos')}'
						}
						contract := 'signals=${sigs.join(',')};e2e=${e2e}'
						for sg in sigs {
							v.sig_frame_id['${iface}|${sg}'] = fid
							v.sig_payload['${iface}|${sg}'] = contract
						}
					}
				}
			}
		}
	}
	// [target].kind — loom2v generates NM only for the threadx target (it forces
	// nm.on = false otherwise), so a non-threadx node is a NM non-participant.
	mut target_threadx := false
	mut target_baremetal := false
	if tv := doc.value_opt('target') {
		kind := (tv.as_map()['kind'] or { toml.Any('') }).string()
		target_threadx = kind == 'threadx'
		target_baremetal = kind == 'baremetal'
	}
	v.is_threadx = target_threadx
	v.is_baremetal = target_baremetal
	// [telemetry] — loom2v requires it (with a bus) for the threadx target, and
	// uses its bus as the implicit NM bus when [nm].bus is absent.
	if tlv := doc.value_opt('telemetry') {
		tm := tlv.as_map()
		tbus := m_str(tm, 'bus')
		// loom2v's threadx gate requires BOTH a telemetry bus AND telemetry on
		// (m.telem.on). parse_telemetry defaults an OMITTED `enabled` to FALSE, so
		// [telemetry] with a bus but no enabled key does NOT satisfy the gate —
		// mirror that default (true would wrongly pass a node loom2v then panics on).
		telem_on := (tm['enabled'] or { toml.Any(false) }).bool()
		v.telem_bus = key_iface[tbus] or { tbus }
		v.has_telemetry = telem_on && tbus != ''
		// the on-wire telemetry frame ids (omitted -> 0; CpuLoad is always sent,
		// so an omitted id still transmits at 0 — see check_telemetry_frames).
		v.telem_id = m_u32(tm, 'id')
		v.telem_detail_id = m_u32(tm, 'detail_id')
	}
	// [someip] — the node's endpoint on a SOME/IP bus. Its `bus` is a LOCAL key, so
	// resolve it to the interface (the node's address) exactly like telemetry: that
	// is the interface its bus-facing signals are keyed by, and the one the system's
	// explicit membership claim has to line up with.
	if sv := doc.value_opt('someip') {
		sm := sv.as_map()
		sbus := m_str(sm, 'bus')
		v.has_someip = true
		v.someip_iface = key_iface[sbus] or { sbus }
		v.someip_service = m_u32(sm, 'service')
		v.someip_version = m_u32(sm, 'version')
		v.someip_peer = m_str(sm, 'peer')
		v.someip_port = m_int(sm, 'port')
	}
	if _ := doc.value_opt('doip') {
		v.has_doip = true
	}
	for d in ecumodel.toml_arr(doc, 'did') {
		dm := d.as_map()
		mut sec := i64(0)
		if w := dm['write'] {
			sec = i64(m_int(w.as_map(), 'security'))
		}
		v.did_writes << doipcfg.DidWrite{
			id:       m_int(dm, 'id')
			writable: m_bool(dm, 'writable') || 'write' in dm
			security: sec
		}
	}
	if bv := doc.value_opt('boot') {
		v.boot = bv is map[string]toml.Any // anything else is the node gate's to refuse
	}
	if uv := doc.value_opt('uds') {
		um := uv.as_map()
		v.uds_security_key = m_str(um, 'security_key')
		if sv := um['services'] {
			v.uds_table = true
			for key, row in sv.as_map() {
				f := key.fields()
				if f.len == 2 {
					// "0x10 02", the handoff's own row; any other sub-function row is the node
					// gate's to refuse, and is no service row either
					if hex_u8(f[0]) == 0x10 && hex_u8(f[1]) == 0x02 {
						v.uds_handoff_security = i64(m_int(row.as_map(), 'security'))
					}
					continue
				}
				// "0x11" — a key that is no SID is the node gate's to refuse
				sid := u8(key.trim_space().to_lower().trim_string_left('0x').parse_uint(16,
					8) or { continue })
				v.uds_rows << doipcfg.ServiceRow{
					sid:      sid
					security: i64(m_int(row.as_map(), 'security'))
				}
			}
		}
	}
	// [trace] — the TraceModule transmits its record frame (record_id, default
	// 0x7e5) AND command responses (rsp_id, default 0x7e3) on the trace bus (the
	// telemetry bus, or [trace].bus for a host runner). parse_trace defaults an
	// omitted `enabled` to TRUE when the block is present.
	if trv := doc.value_opt('trace') {
		trm := trv.as_map()
		v.trace_on = (trm['enabled'] or { toml.Any(true) }).bool()
		tb := m_str(trm, 'bus')
		v.trace_bus = key_iface[tb] or { tb }
		v.trace_level = (trm['level'] or { toml.Any('thread+fb') }).string()
		v.trace_push_ms_set = 'push_ms' in trm
		if v.trace_on {
			v.trace_record_id, v.trace_record_name = binding_id(trm, 'record', 0x7e5)
			v.trace_rsp_id, v.trace_rsp_name = binding_id(trm, 'rsp', 0x7e3)
			v.trace_cmd_id, v.trace_cmd_name = binding_id(trm, 'cmd', 0x7e2)
			v.trace_dump_fc_id, v.trace_dump_fc_name = binding_id(trm, 'dump_fc', 0x7e6)
			v.trace_dump_fc_bound = 'dump_fc' in trm
		}
	}
	// [isotp] — the node's diagnostic connection. rx_id/tx_id are on-wire diagnostic
	// CAN ids. The old [[isotp]] array is still READ here — the node gate refuses it, with the
	// move it needs, but a partial node (sysgen's dissolution path) runs no gate, and its ids
	// must not drop out of the collision checks.
	if iv := doc.value_opt('isotp') {
		mut tables := []toml.Any{}
		if iv is map[string]toml.Any {
			tables << iv
		} else if iv is []toml.Any {
			tables = iv.clone()
		}
		for c in tables {
			cm := c.as_map()
			v.has_isotp = true
			bus := m_str(cm, 'bus')
			v.isotp_conns << IsotpConn{
				iface:         key_iface[bus] or { bus }
				rx_id:         m_u32(cm, 'rx_id')
				tx_id:         m_u32(cm, 'tx_id')
				functional_id: m_u32(cm, 'functional_id')
			}
		}
	}
	// [shell] — the threadx comm thread transmits shell.out responses (default
	// 0x7f1). parse_shell defaults an omitted `enabled` to TRUE when present.
	if shv := doc.value_opt('shell') {
		sm := shv.as_map()
		v.shell_on = (sm['enabled'] or { toml.Any(true) }).bool()
		// resolved as loom2v resolves it: an omitted bus inherits [telemetry].bus
		v.shell_bus = ecumodel.module_bus(doc, 'shell')
		if v.shell_on {
			v.shell_out_id, v.shell_out_name = binding_id(sm, 'out', 0x7f1)
			v.shell_in_id, v.shell_in_name = binding_id(sm, 'in', 0x7f0)
			v.shell_fc_id, v.shell_fc_name = binding_id(sm, 'fc', 0x7f2)
		}
	}
	// [nm] cluster + identity
	if nmv := doc.value_opt('nm') {
		m := nmv.as_map()
		v.has_nm = true
		// enabled = false OR a non-threadx target = a declared-but-inactive NM
		// (loom2v emits no NM): a non-participant, so the cluster/alive/allocation/
		// uniqueness checks skip it.
		v.nm_enabled = (m['enabled'] or { toml.Any(true) }).bool() && target_threadx
		// the bus this node runs NM on: [nm].bus if set, else the telemetry bus
		// (loom2v uses m.telem.bus when nm.bus is absent), resolved to its interface.
		nmbus := m_str(m, 'bus')
		if nmbus != '' {
			v.nm_bus = key_iface[nmbus] or { nmbus }
		} else {
			v.nm_bus = v.telem_bus
		}
		v.has_nm_node = 'node' in m // node id 0 is valid — distinguish from absent
		// keep the SIGNED value long enough to range-check: loom2v rejects a node
		// id outside 0..255, but m_u32 would turn -1 into a huge value that could
		// collide (REQ-TOPO-005 "clean system => buildable nodes").
		node_raw := (m['node'] or { toml.Any(0) }).int()
		v.nm_node = u32(node_raw)
		v.nm_node_ok = node_raw >= 0 && node_raw <= 255
		// peers range: loom2v defaults an omitted range to 0x500..0x53f (its NmCfg
		// defaults), and derives alive from that base — so default it here too.
		peers := (m['peers'] or { toml.Any([]toml.Any{}) }).array()
		if peers.len == 2 {
			v.peers_lo = u32(peers[0].int())
			v.peers_hi = u32(peers[1].int())
		} else {
			v.peers_lo = 0x500
			v.peers_hi = 0x53f
		}
		// alive: NUMERIC literal -> that id; DBC message NAME -> loom2v resolves it
		// to a CAN id (record the NAME for a name-level collision check); ABSENT ->
		// loom2v derives peers_lo + node, so derive + range-check the SAME value.
		if av := m['alive'] {
			if av is string {
				v.alive_binding = av
			} else {
				v.alive = u32(av.int())
				v.has_alive = true
			}
		} else if v.has_nm_node {
			v.alive = v.peers_lo + v.nm_node
			v.has_alive = true
		}
		// timing: presence tracked so an EXPLICIT 0 is preserved (loom2v applies
		// its default only when the key is ABSENT — an explicit 0 stays 0).
		v.nm_has_msg_cycle = 'msg_cycle_ms' in m
		v.nm_has_timeout = 'timeout_ms' in m
		v.nm_has_repeat = 'repeat_ms' in m
		v.nm_has_wait_sleep = 'wait_sleep_ms' in m
		v.nm_msg_cycle_ms = m_int(m, 'msg_cycle_ms')
		v.nm_timeout_ms = m_int(m, 'timeout_ms')
		v.nm_repeat_ms = m_int(m, 'repeat_ms')
		v.nm_wait_sleep_ms = m_int(m, 'wait_sleep_ms')
	}
	// comm_thread_on = threadx target WITH a bridge (>=1 external bus signal or an
	// ISO-TP connection). loom2v emits the NM state machine, the threadx trace
	// module, and the shell ONLY inside that comm thread — so a bridgeless threadx
	// node runs none of them, and its NM must NOT count as an active participant
	// (else syscheck reports a coherent cluster / duplicate ids that never hit the
	// wire). Gate nm_enabled on it, matching loom2v's runtime behaviour.
	mut has_bus_sig := false
	for _, sigs in v.produces {
		if sigs.len > 0 {
			has_bus_sig = true
		}
	}
	for _, sigs in v.consumes {
		if sigs.len > 0 {
			has_bus_sig = true
		}
	}
	v.comm_thread_on = v.is_threadx && (has_bus_sig || v.has_isotp)
	v.nm_enabled = v.nm_enabled && v.comm_thread_on
	return v
}

// run_capture runs `exe` with an ARGUMENT VECTOR (never a shell command string),
// so a node/DBC path containing shell metacharacters (`$(...)`, backticks, `;`)
// is passed to the child literally and can never trigger command substitution —
// syscheck loads whatever paths a system.toml names, so those are untrusted
// input. Returns combined stdout+stderr and the exit code.
fn run_capture(exe string, args []string) (string, int) {
	mut p := os.new_process(exe)
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	out := p.stdout_slurp() + p.stderr_slurp()
	p.wait()
	code := p.code
	p.close()
	return out, code
}

// ecucheck_errors runs the real per-node gate (tools/ecucheck) on a node's
// ecu.toml and returns its error lines (empty = clean). Running the REAL @VEXE
// keeps this the EXACT validation loom2v builds behind — no re-implementation to
// drift. ecucheck prints "<file>: <msg>" per error and a "ecucheck: N …"
// summary, then exits non-zero; we keep the messages, drop the summary/prefix.
// v_compiler_noise reports whether a captured line is the V COMPILER talking about our own
// source, not the tool talking about the config. The tools are built apart now (build_tool), so
// a successful build's notices no longer reach this stream; kept for a tool that itself runs
// the compiler. Under `v run` a notice or warning in any transitively-compiled file landed on
// the same stream as the tool's output --
// so an unrelated `notice: shifting a value from a signed type` in ecumodel.v was being
// reported as a config error, four lines of source echo and carets with it. Harmless while
// only sysgen surfaced them; syscheck now reports the same lines as system errors (#277).
fn v_compiler_noise(t string) bool {
	if t.contains('.v:') && (t.contains(': notice:') || t.contains(': warning:')
		|| t.contains(': error:')) {
		return true
	}
	// the source echo the compiler prints under a diagnostic: "1468 |         code"
	if t.len > 0 && t[0].is_digit() && t.contains(' | ') {
		return true
	}
	// ...and the caret/tilde underline beneath it
	if t.starts_with('|') || t.starts_with('~') || t.starts_with('^') {
		return true
	}
	return false
}

// is_someip_leaf reports whether a node is a member of a someip segment AND sits on exactly one
// CAN bus, routing nothing between them — nodes/tester: an LED on compute, tcu's peer on tel.
//
// It exists because that shape has to be recognised in FOUR places and they must agree: two
// dissolution checks (a multi-bus node must otherwise be a route gateway, and a gateway may not
// carry its own signals), the lowering that emits both halves, and the loom2v precheck that
// would otherwise skip the node as a "gateway". The first version of this change spelled the
// rule out at each site; tester then lowered as a gateway and silently lost its loom2v gate.
pub fn (s System) is_someip_leaf(n Node) bool {
	mut someip := 0
	mut can := 0
	for bn in n.buses {
		bus := s.bus_by_name(bn) or { return false }
		if bus.kind == 'someip' {
			someip++
		} else {
			can++
		}
	}
	return someip == 1 && can == 1 && !is_route_gateway(s, n.name)
}

// someip_event_producer: the node that sends event `fr` — the producer of its signals (one owner
// per frame is check_signals_dissolved's rule). '' when none of its signals is declared.
pub fn (s System) someip_event_producer(fr SysFrame) string {
	for sg in fr.signals {
		if sig := s.signal_by_name(sg) {
			return sig.producer
		}
	}
	return ''
}

// someip_members: the nodes that name someip bus `bus` in `buses`, in declaration order.
pub fn (s System) someip_members(bus string) []Node {
	return s.nodes.filter(bus in it.buses)
}

// someip_event_receivers: the members of fr's segment, other than its producer, whose FBs read
// any of its signals, in node declaration order. An event is UNICAST — the generated bridge sends
// each datagram to one static address, with no service discovery and no multicast — so
// check_someip_segment holds this to one; on a TWO-member segment the other member is the
// receiver whether or not it reads (the point-to-point rule the segment started with, whose
// partial-subscriber diagnostics name the missing reads).
pub fn (s System) someip_event_receivers(fr SysFrame) []string {
	producer := s.someip_event_producer(fr)
	members := s.someip_members(fr.bus)
	mut out := []string{}
	for n in members {
		if n.name == producer {
			continue
		}
		if fr.signals.any(it in n.view.fb_reads) {
			out << n.name
		}
	}
	if out.len == 0 && members.len == 2 && producer != '' {
		for n in members {
			if n.name != producer {
				out << n.name
			}
		}
	}
	return out
}

// someip_partners: the members `n` exchanges events with on someip bus `bus` — the receiver of
// each event it sends and the producer of each event it receives — ordered by the first event
// (system [[frame]] order) that connects them, without repeats. The first is the node's
// [someip].peer (its default: where an RPC answer goes and whom an RPC request is accepted
// from); an event exchanged with any other partner carries that partner as its own `peer`.
//
// A two-member segment's partner is the other member even when no event connects them — the
// original point-to-point segment, which a member may join to serve RPC alone.
pub fn (s System) someip_partners(n Node, bus string) []string {
	members := s.someip_members(bus)
	if members.len == 2 {
		return members.filter(it.name != n.name).map(it.name)
	}
	mut out := []string{}
	for fr in s.frames {
		if fr.bus != bus {
			continue
		}
		p := s.someip_event_partner(n, fr) or { continue }
		if p !in out {
			out << p
		}
	}
	return out
}

// someip_event_partner: who `n` exchanges event `fr` with — its receiver when n sends it, its
// producer when n receives it; none when n is neither end (or the event has no single receiver,
// which check_someip_segment refuses).
pub fn (s System) someip_event_partner(n Node, fr SysFrame) ?string {
	producer := s.someip_event_producer(fr)
	receivers := s.someip_event_receivers(fr)
	if producer == n.name {
		if receivers.len == 1 {
			return receivers[0]
		}
		return none
	}
	if n.name in receivers && producer != '' {
		return producer
	}
	return none
}

// build_tool compiles a repo tool into `dir` (a private directory the caller owns) and returns
// the binary's path — `.exe` on Windows, which is what `v -o` writes there. Never `v run`: that
// compiles to a path derived from the tool's source and deletes the binary when it exits, so two
// concurrent runs of one tool (parallel tests, syscheck beside sysgen) share one file and one
// deletes it under the other — `generated tcu: No such file or directory` (#313).
pub fn build_tool(src string, globals bool, dir string) !string {
	mut bin := os.join_path(dir, os.file_name(src).all_before('.'))
	$if windows {
		bin += '.exe'
	}
	mut args := if globals { ['-enable-globals'] } else { []string{} }
	args << ['-o', bin, src]
	out, code := run_capture(@VEXE, args)
	if code != 0 {
		return error('cannot build ${src}: ${out.trim_space()}')
	}
	return bin
}

// run_tool builds a tool into a fresh private directory, runs it there and removes it. A
// tool that does not BUILD is an error, kept apart from what the tool says about the config.
pub fn run_tool(src string, globals bool, args []string) !(string, int) {
	dir := private_temp_dir('blobly_tool')!
	defer {
		os.rmdir_all(dir) or {}
	}
	bin := build_tool(src, globals, dir)!
	out, code := run_capture(bin, args)
	return out, code
}

pub fn ecucheck_errors(node_path string) []string {
	output, code := run_tool('${@VMODROOT}/tools/ecucheck/gen.v', false, [node_path]) or {
		return [err.msg()]
	}
	if code == 0 {
		return []string{}
	}
	fname := os.file_name(node_path)
	mut out := []string{}
	for line in output.split_into_lines() {
		t := line.trim_space()
		if t == '' || t.starts_with('ecucheck:') {
			continue // the count summary, not an error
		}
		if v_compiler_noise(t) {
			continue
		}
		// strip the leading "<fname>: " ecucheck prepends
		out << t.trim_string_left('${fname}: ')
	}
	if out.len == 0 {
		// ecucheck failed for a reason it didn't print as a schema error (a
		// build/parse failure) — surface something rather than swallow it.
		out << 'ecucheck failed (exit ${code})'
	}
	return out
}

// private_temp_dir creates a scratch directory that nobody else can have pre-staged.
//
// A name derived from the PID is PREDICTABLE, so on a shared temp directory another process can
// create it first and fill it with symlinks -- `gen-<node>.toml`, or a staged DBC path. sysgen
// then accepts the existing directory, every lexical containment check still passes because the
// paths themselves are fine, and write_file/cp FOLLOW the symlinks: anything writable by this
// user gets overwritten outside the scratch tree (codex on #279).
//
// os.mkdir wraps mkdir(2), which fails with EEXIST -- so creating the directory IS the check.
// 0o700 keeps it private afterwards, and an unpredictable name means there is nothing to
// pre-create. Used for every scratch tree here, not only the one that was reported.
pub fn private_temp_dir(prefix string) !string {
	for _ in 0 .. 16 {
		cand := os.join_path(os.temp_dir(), '${prefix}_${rand.u64().hex()}${rand.u32().hex()}')
		os.mkdir(cand, os.MkdirParams{ mode: 0o700 }) or { continue }
		return cand
	}
	return error('could not create a private scratch directory under ${os.temp_dir()}')
}

// sysgen_errors LOWERS the system with the real tools/sysgen into a scratch directory and
// returns what the node gate says about the result (empty = clean).
//
// This is the same trick loom2v_errors plays one level down, and for the same reason. The
// dissolved model is only half a contract: system.toml declares wiring that becomes a node
// config, and every rule about that config is owned by ecucheck and loom2v -- the derived
// SOME/IP payload's size and alignment, the E2E trailer's exact offsets, the tx-mode enum,
// the byte-IOC channel ceiling, a bindable interface address. Restating any of them here
// produces a SECOND, partial copy that drifts (blobly_emb#276 rounds 4-6 were a dozen
// findings of exactly that shape, each one "syscheck says OK, the node build refuses").
// Lowering for real means there is one gate, not two that agree until they do not.
//
// `out_dir` is a scratch directory: sysgen --out writes the generated configs and copies each
// referenced DBC there, so nothing touches the source tree.
pub fn sysgen_errors(system_path string, out_dir string) []string {
	output, code := run_tool('${@VMODROOT}/tools/sysgen', true, [system_path, '--out', out_dir]) or {
		return [err.msg()]
	}
	if code == 0 {
		return []string{}
	}
	mut out := []string{}
	for line in output.split_into_lines() {
		t := line.trim_space()
		if t == '' || !t.starts_with('sysgen:') {
			continue
		}
		body := t.all_after('sysgen:').trim_space()
		// the per-node "<node> -> <path> (ok)" progress lines are not errors; a refusal may
		// contain an arrow of its own, so match the progress line's whole shape
		if (body.contains(' -> ') && body.ends_with('(ok)')) || body.starts_with('refusing to generate') {
			continue
		}
		out << body
	}
	if out.len == 0 {
		out << 'lowering failed (exit ${code})'
	}
	return out
}

// dbcmerge_errors runs the REAL tools/dbcmerge — the step a gateway node's Makefile runs
// before loom2v — merging `ins` into `out`. A gateway speaks a DBC per bus and loom2v consumes
// one, so the system gate merges them the same way the node build does and then hands loom2v
// the result: both gates refuse with the same code (#351). Empty = merged.
pub fn dbcmerge_errors(out string, ins []string) []string {
	mut args := [out]
	args << ins
	output, code := run_tool('${@VMODROOT}/tools/dbcmerge/gen.v', false, args) or {
		return ['dbcmerge: ${err.msg()}']
	}
	if code == 0 {
		return []string{}
	}
	mut errs := []string{}
	for line in output.split_into_lines() {
		t := line.trim_space()
		if t.starts_with('dbcmerge:') {
			errs << t
		}
	}
	if errs.len == 0 {
		errs = panic_lines(output).map('dbcmerge: ${it}')
	}
	if errs.len == 0 {
		errs << 'dbcmerge: failed (exit ${code})'
	}
	return errs
}

// panic_lines: what a tool's V panics said, for a failure the tool did not word as its own
fn panic_lines(output string) []string {
	mut out := []string{}
	for line in output.split_into_lines() {
		t := line.trim_space()
		if t.starts_with('V panic:') {
			out << t.all_after('V panic:').trim_space()
		}
	}
	return out
}

// loom2v_errors runs the REAL generator (tools/loom2v) on a node's ecu.toml with
// its bus DBC, returning any panic lines (empty = clean). ecucheck validates the
// SCHEMA; loom2v enforces every TARGET-dependent constraint ecucheck can't see —
// the threadx comm-thread bridge (trivial-u32 signals, standard 11-bit ids), the
// single-local-partition rule, comm-owner priority, trace-setting limits, the
// telemetry-bus-must-exist rule, ISO-TP/routes-not-generated. Shelling the
// generator keeps "clean syscheck => buildable node" EXACT — no reimplementation
// to drift. `dbc_path` is the node's bus DBC (loom2v resolves external signals
// against it); '' when the bus declares none. Outputs go to a temp dir, discarded.
pub fn loom2v_errors(node_path string, dbc_path string) []string {
	tmp := private_temp_dir('syscheck_loom') or { return ['loom2v: cannot create temp dir: ${err}'] }
	defer {
		os.rmdir_all(tmp) or {}
	}
	sig := os.join_path(tmp, 'signals.v')
	ports := os.join_path(tmp, 'ports.v')
	glue := os.join_path(tmp, 'glue.v')
	man := os.join_path(tmp, 'manifest.toml')
	output, code := run_tool('${@VMODROOT}/tools/loom2v', true, [node_path, dbc_path, sig, ports,
		glue, man]) or { return [err.msg()] }
	if code == 0 {
		return []string{}
	}
	mut out := []string{}
	for line in output.split_into_lines() {
		t := line.trim_space()
		// keep the generator's own diagnostics (its panics carry "loom2v:")
		if t.contains('loom2v:') {
			out << t.all_after('loom2v:').trim_space()
		}
	}
	if out.len == 0 {
		// a failure loom2v did not word as its own (a panic from V or a library it calls) is still
		// a refusal: keep what the panic said rather than only that it happened
		out = panic_lines(output)
	}
	if out.len == 0 {
		out << 'loom2v generation failed (exit ${code})'
	}
	return out
}

// hex_u8: "0x10" / "10" as a byte, -1 when it is not one
fn hex_u8(s string) int {
	h := s.trim_space().to_lower().trim_string_left('0x')
	if h.len == 0 || h.len > 2 || !h.bytes().all(it.is_hex_digit()) {
		return -1
	}
	return int(h.parse_uint(16, 8) or { return -1 })
}
