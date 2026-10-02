// loom2v's COM TRANSPORT codegen: the CAN host bus bridge and the Ethernet /
// SOME/IP frame table, codec and bridge (docs/someip.md). Extracted verbatim from
// gen.v; same `module main`, so no imports change.
module main

import toml
import tools.ecumodel

struct SomeipCfg {
mut:
	on      bool
	bus     string
	service int
	version int
	port    int
	peer    string
}

// EthFrame is one eth [[frame]]: the SOME/IP event id + the derived layout.
struct EthFrame {
mut:
	name        string // config spelling
	id          int    // event id (bit 15 set — validated)
	tx          bool   // direction: signals to the bus (else rx)
	signals     []string
	layout      []EthField
	len         int  // total payload bytes (E2E trailer included)
	e2e_on      bool // loss protection: the appended counter+CRC trailer
	e2e_id      int
	e2e_tmo_us  int // a received frame's E2E-owned sender-loss timeout (REQ-E2E-002); 0 = none
	tx_mode     string // cyclic | change | mixed (tx frames)
	tx_cycle_us int
	tx_min_us   int
}

fn parse_someip(doc toml.Doc) SomeipCfg {
	mut s := SomeipCfg{}
	if sv := doc.value_opt('someip') {
		sm := sv.as_map()
		s.on = true
		s.bus = (sm['bus'] or { toml.Any('') }).string()
		s.service = int((sm['service'] or { toml.Any(0) }).int())
		s.version = int((sm['version'] or { toml.Any(0) }).int())
		s.port = int((sm['port'] or { toml.Any(0) }).int())
		s.peer = (sm['peer'] or { toml.Any('') }).string()
	}
	return s
}

// parse_eth_frames builds each eth frame's derived layout from the signal
// declarations: signals in list order, fields NAME-SORTED within a signal
// (TOML table key order is not data — docs/someip.md), byte-aligned LE at
// natural widths, the optional E2E trailer appended.
fn parse_eth_frames(doc toml.Doc, eth string, sig_of map[string]SigInfo) []EthFrame {
	mut out := []EthFrame{}
	if eth == '' {
		return out
	}
	for f in ecumodel.toml_arr(doc, 'frame') {
		fm := f.as_map()
		if (fm['bus'] or { toml.Any('') }).string() != eth {
			continue
		}
		fname := (fm['name'] or { toml.Any('') }).string()
		mut fr := EthFrame{
			name:        fname
			id:          int((fm['id'] or { toml.Any(0) }).int())
			tx_mode:     'cyclic'
			tx_cycle_us: 100_000
		}
		if txv := fm['tx'] {
			txm := txv.as_map()
			fr.tx_mode = (txm['mode'] or { toml.Any('cyclic') }).string()
			fr.tx_cycle_us = int((txm['cycle_ms'] or { toml.Any(100) }).int()) * 1000
			fr.tx_min_us = int((txm['min_delay_ms'] or { toml.Any(0) }).int()) * 1000
		}
		mut off := 0
		for sv in (fm['signals'] or { toml.Any([]toml.Any{}) }).array() {
			sname := sv.string()
			fr.signals << sname
			si := sig_of[sname] or {
				panic('loom2v: eth frame "${fname}" lists unknown signal "${sname}"')
			}
			if !fr.tx && !si.rx {
				fr.tx = true
			}
		}
		// the layout comes from ecumodel.eth_layouts — the SINGLE derivation
		// (sigmap and the manifest read the same one, so they cannot drift)
		for cell in ecumodel.eth_layouts(doc) {
			if cell.frame != fname {
				continue
			}
			fr.layout << EthField{
				sig:    cell.sig
				field:  cell.field
				offset: cell.offset
				width:  cell.width
				typ:    cell.typ
			}
			if cell.offset + cell.width > off {
				off = cell.offset + cell.width
			}
		}
		if ev := fm['e2e'] {
			evm := ev.as_map()
			if tv := evm['timeout_ms'] {
				if fr.tx {
					panic('loom2v: eth frame "${fname}" sets e2e.timeout_ms, but it is SENT — the E2E timeout watches a RECEIVED frame for loss of its sender')
				}
				if tv !is i64 {
					panic('loom2v: eth frame "${fname}": e2e.timeout_ms must be an integer number of ms, got ${tv.string()}')
				}
				fr.e2e_tmo_us = ms_to_us(tv.i64(), 'eth frame "${fname}": e2e.timeout_ms')
			}
			fr.e2e_on = true
			fr.e2e_id = int((evm['data_id'] or { toml.Any(0) }).int())
			off += 2 // the appended counter + CRC trailer (docs/someip.md)
		}
		fr.len = off
		out << fr
	}
	return out
}

// someip_manifest: the eth service identity + each frame's DERIVED layout, so
// the host oracle (blobly_net modules/someip) decodes the payload from the
// same source of truth as the generated codec (docs/someip.md).
fn someip_manifest(m Model) []string {
	// identity keys on [someip] itself — a module-only eth service (trace/telem
	// bound, no [[frame]]) still needs the oracle to know who it is
	if !m.someip.on {
		return []
	}
	mut rows := ['# someip: service,version,port,peer']
	rows << 'someip,0x${m.someip.service.hex()},${m.someip.version},${m.someip.port},${m.someip.peer}'
	// module bindings on the eth bus: telemetry's fixed CpuLoad/LoadDetail
	// payloads ride the configured event ids — trace's ids already appear in
	// its own manifest section, telemetry has no other emitter
	if m.telem.on && (m.bus_kind[m.telem.bus] or { 'can' }) == 'eth' {
		rows << '# eth modules: module,endpoint,id'
		rows << 'ethmod,telemetry,cpuload,0x${m.telem.id.hex()}'
		if m.telem.detail_id != 0 {
			rows << 'ethmod,telemetry,detail,0x${m.telem.detail_id.hex()}'
		}
	}
	if m.eth_frames.len == 0 {
		return rows
	}
	rows << '# eth frames: frame,id,len,dir,mode,cycle_us,e2e_id'
	for fr in m.eth_frames {
		dir := if fr.tx { 'tx' } else { 'rx' }
		e2e := if fr.e2e_on { '0x${fr.e2e_id.hex()}' } else { '-' }
		rows << 'ethframe,${fr.name},0x${fr.id.hex()},${fr.len},${dir},${fr.tx_mode},${fr.tx_cycle_us},${e2e}'
	}
	rows << '# eth layout: frame,signal,field,offset,width,type'
	for fr in m.eth_frames {
		for cell in fr.layout {
			rows << 'ethlayout,${fr.name},${cell.sig},${cell.field},${cell.offset},${cell.width},${cell.typ}'
		}
	}
	return rows
}

// emit_bridges emits the host COM bus bridge(s): per external bus, decode rx -> IOC cells and
// encode IOC cells -> tx frames (+ raw routes, ISO-TP, E2E/SecOC). Skipped for the ThreadX
// comm-thread target (comm_thread_on), which owns rx in its own comm_thread_entry. Returns the
// glue lines plus the bus_names / bus_dests the run() emitters need; reads the Model, with the
// derived scratch/thread layout (telem_slot, comm_tid, trace bases) from main's emit-time state.
// telem_on_can: the telemetry CAN machinery (the driver.can channel + the
// partition_telem thread) is emitted only for a CAN-bus binding — an eth
// telemetry binding is the SOME/IP UDP producer, which is the UDP rung;
// emitting the CAN path for it would open SocketCAN on an IP address.
// route_field is the state-field prefix for a signal route's stored value/freshness
// (unique per destination bus + frame + signal).
fn route_field(r Route) string {
	return 'rt_${snake(r.to_bus)}_${snake(r.to_frame)}_${snake(r.signal)}'
}

// raw_field names the per-raw-route pending-frame slot (a frame route keeps the
// tx-ready gate: if the destination TX can't accept the send yet, the PDU is held
// and retried next tick rather than silently dropped — REQ-TOPO-010).
fn raw_field(r Route) string {
	return 'rr_${snake(r.to_bus)}_${r.from_id.hex()}_${if r.from_ext { 'e' } else { 's' }}'
}

fn telem_on_can(m Model) bool {
	return m.telem.on && (m.bus_kind[m.telem.bus] or { 'can' }) != 'eth'
}

// emit_eth_codec emits the SOME/IP eth frame table + derived-layout codec
// (docs/someip.md): the [someip] identity consts, per-frame event-id/len
// consts, and a no-alloc pack fn per TX frame writing each field at its
// natural width, little-endian, in canonical order (signals-list order,
// name-sorted fields). The DBC-codec analog for the eth bus — the tx loop
// that wraps these payloads in the comm/someip header is the UDP rung; rx
// unpack is the rx rung (consts only here).
fn emit_eth_codec(m Model) []string {
	mut glue := []string{}
	// identity keys on [someip] itself — a module-only eth service (trace/telem
	// bound, no [[frame]]) still needs its runtime identity/endpoint consts
	if !m.someip.on {
		return glue
	}
	glue << ''
	glue << '// --- SOME/IP eth frames (docs/someip.md): derived-layout codec ---'
	glue << ''
	glue << 'pub const someip_service = u16(0x${m.someip.service.hex()})'
	glue << 'pub const someip_version = u8(${m.someip.version})'
	glue << 'pub const someip_port = u16(${m.someip.port})'
	// the peer as fixed-width scalars — a `string` const in generated runtime
	// code would violate no-alloc (AGENTS.md), inferred type or not
	oct, pport := peer_parts(m.someip.peer)
	glue << 'pub const someip_peer_ip = [u8(${oct[0]}), ${oct[1]}, ${oct[2]}, ${oct[3]}]!'
	glue << 'pub const someip_peer_port = u16(${pport})'
	for fr in m.eth_frames {
		fb := snake(fr.name)
		dir := if fr.tx { 'tx' } else { 'rx' }
		e2e_note := if fr.e2e_on { ' (incl. 2-byte E2E trailer)' } else { '' }
		glue << ''
		glue << '// ${fr.name}: ${dir} event 0x${fr.id.hex()}, ${fr.len}-byte payload${e2e_note}'
		glue << 'pub const ${fb}_event_id = u16(0x${fr.id.hex()})'
		glue << 'pub const ${fb}_len = u8(${fr.len})'
		if fr.e2e_on {
			// the trailer sits after the signal layout: counter, then CRC
			glue << 'pub const ${fb}_e2e_id = u16(0x${fr.e2e_id.hex()})'
			glue << 'pub const ${fb}_e2e_ctr = ${fr.len - 2}'
			glue << 'pub const ${fb}_e2e_crc = ${fr.len - 1}'
		}
		if !fr.tx {
			// the rx unpack: pack's exact inverse — each field read at its
			// natural width, LE, from the same canonical offsets
			mut uparams := []string{}
			for s in fr.signals {
				uparams << 'mut s_${snake(s)} sig.${s}'
			}
			glue << '// 64 = com.max_pdu (a literal: V codegen mishandles const-sized mut fixed-array params)'
			glue << 'pub fn ${fb}_unpack(d [64]u8, ${uparams.join(', ')}) {'
			for cell in fr.layout {
				tgt := 's_${snake(cell.sig)}.${cell.field}'
				o := cell.offset
				match cell.typ {
					'bool' {
						glue << '\t${tgt} = d[${o}] != 0'
					}
					'f32', 'f64' {
						// bit-copy: host and target are both little-endian
						glue << '\tunsafe {'
						glue << '\t\tup_${o} := &u8(&${tgt})'
						glue << '\t\tfor i in 0 .. ${cell.width} {'
						glue << '\t\t\tup_${o}[i] = d[${o} + i]'
						glue << '\t\t}'
						glue << '\t}'
					}
					else {
						// integer scalars: LE compose through u64, then the
						// narrowing cast truncates/sign-adjusts to the field type
						mut parts := []string{}
						for i in 0 .. cell.width {
							if i == 0 {
								parts << 'u64(d[${o}])'
							} else {
								parts << '(u64(d[${o + i}]) << ${i * 8})'
							}
						}
						glue << '\t${tgt} = ${cell.typ}(${parts.join(' | ')})'
					}
				}
			}
			glue << '}'
			continue
		}
		mut params := []string{}
		for s in fr.signals {
			params << 's_${snake(s)} sig.${s}'
		}
		glue << '// 64 = com.max_pdu (a literal: V codegen mishandles const-sized mut fixed-array params)'
		glue << 'pub fn ${fb}_pack(mut d [64]u8, ${params.join(', ')}) {'
		for cell in fr.layout {
			expr := 's_${snake(cell.sig)}.${cell.field}'
			o := cell.offset
			match cell.typ {
				'bool' {
					glue << '\td[${o}] = if ${expr} { u8(1) } else { u8(0) }'
				}
				'f32', 'f64' {
					// bit-copy: host and target are both little-endian
					glue << '\tunsafe {'
					glue << '\t\tfp_${o} := &u8(&${expr})'
					glue << '\t\tfor i in 0 .. ${cell.width} {'
					glue << '\t\t\td[${o} + i] = fp_${o}[i]'
					glue << '\t\t}'
					glue << '\t}'
				}
				else {
					// integer scalars: LE shifts through the unsigned widening cast
					for i in 0 .. cell.width {
						if i == 0 {
							glue << '\td[${o}] = u8(${expr})'
						} else {
							glue << '\td[${o + i}] = u8(u64(${expr}) >> ${i * 8})'
						}
					}
				}
			}
		}
		glue << '}'
	}
	return glue
}

// emit_eth_bridge emits the eth comm thread (docs/someip.md): the tx side
// acquires each tx frame's signals from IOC, packs the derived layout, gates
// on com.TxState (the same cyclic/event/mixed machinery as CAN), stamps the
// E2E trailer when configured, wraps in the comm/someip notification header,
// and sends one datagram to the static peer through the driver/eth seam. The
// rx side drains the same socket: source filter (REQ-NET-017) -> envelope
// gate (REQ-NET-015) -> route by event id -> unpack -> IOC publish, every
// refusal a counted drop, never a fault.
fn emit_eth_bridge(m Model) []string {
	mut glue := []string{}
	mut tx_frames := []EthFrame{}
	mut rx_frames := []EthFrame{}
	for fr in m.eth_frames {
		if fr.tx {
			tx_frames << fr
		} else {
			rx_frames << fr
		}
	}
	if m.eth_frames.len == 0 {
		return glue
	}
	eb := snake(m.eth)
	glue << ''
	glue << '// --- eth comm thread (${m.eth}): SOME/IP event tx over the UDP seam ---'
	glue << 'pub fn partition_${eb}(sock eth.Socket) {'
	glue << '\tosal.pin_to_core(${m.bus_core[m.eth] or { 0 }})'
	for fr in tx_frames {
		fb := snake(fr.name)
		glue << '\tmut tx_${fb}_st := com.TxState{'
		glue << '\t\tmode: com.TxMode.${fr.tx_mode}'
		glue << '\t\tcycle_us: ${fr.tx_cycle_us}'
		glue << '\t\tmin_delay_us: ${fr.tx_min_us}'
		glue << '\t}'
		if fr.e2e_on {
			glue << '\tmut e2e_tx_${fb} := e2e.TxState{}'
		}
	}
	if tx_frames.len > 0 {
		glue << '\tmut dgram := [80]u8{} // someip.header_len + com.max_pdu'
	}
	for fr in rx_frames {
		glue << eth_rx_e2e_init(fr, 'osal.now_us()')
	}
	if rx_frames.len > 0 {
		glue << '\tmut rx_buf := [80]u8{} // someip.header_len + com.max_pdu — an oversize datagram truncates here and fails the Length gate'
		glue << '\tmut rx_ip := [4]u8{}'
		glue << '\tmut rx_port := u16(0)'
		glue << '\tmut rx_drops := u32(0) // every refusal counted, never faulting (REQ-NET-015)'
		glue << '\tmut rx_drops_told := u32(0)'
		glue << '\tmut rx_told_at := u64(0)'
	}
	glue << '\tfor {'
	glue << '\t\tnow := osal.now_us()'
	if rx_frames.len > 0 {
		glue << '\t\t// drain pending datagrams — BOUNDED, so a flood cannot starve the'
		glue << '\t\t// tx work below — and COALESCE per frame: signals are state (IOC'
		glue << '\t\t// keeps only the latest), so one publish per pass delivers the same'
		glue << '\t\t// values without back-to-back publishes lapping an app-side reader'
		for fr in rx_frames {
			fb := snake(fr.name)
			glue << '\t\tmut got_${fb} := false'
			for s in fr.signals {
				glue << '\t\tmut rxs_${snake(s)} := sig.${s}{}'
			}
		}
		glue << '\t\tfor _ in 0 .. 16 {'
		glue << '\t\t\trx_n := sock.recv(mut rx_ip, &rx_port, &rx_buf[0], 80)'
		glue << '\t\t\tif rx_n < 0 {'
		glue << '\t\t\t\tbreak // nothing pending — a zero-length datagram is REAL'
		glue << '\t\t\t}'
		glue << '\t\t\t// ... and falls through: decode rejects it as short, so an empty-'
		glue << '\t\t\t// datagram stream is counted AND cannot throttle the bounded drain'
		glue << '\t\t\t// recv reports the REAL datagram length (MSG_TRUNC): an oversize'
		glue << '\t\t\t// datagram was truncated into the buffer — drop, never decode a prefix'
		glue << '\t\t\tif rx_n > 80 {'
		glue << '\t\t\t\trx_drops++'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		glue << '\t\t\t// static-peer source filter (REQ-NET-017): SD-less, the configured'
		glue << '\t\t\t// endpoint is the only legal talker — anyone else is a counted drop'
		glue << '\t\t\tif rx_ip[0] != someip_peer_ip[0] || rx_ip[1] != someip_peer_ip[1] || rx_ip[2] != someip_peer_ip[2] || rx_ip[3] != someip_peer_ip[3] || rx_port != someip_peer_port {'
		glue << '\t\t\t\trx_drops++'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		glue << '\t\t\trh, rh_ok := someip.decode(&rx_buf[0], rx_n)'
		glue << '\t\t\tif !rh_ok || someip.check_event(rh, rx_n, someip_service, someip_version) != .none {'
		glue << '\t\t\t\trx_drops++'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		for i, fr in rx_frames {
			fb := snake(fr.name)
			kw := if i == 0 { 'if' } else { '} else if' }
			glue << '\t\t\t${kw} rh.method == ${fb}_event_id {'
			glue << '\t\t\t\t// the router\'s length check: the payload IS the frame, exactly'
			glue << '\t\t\t\tif rx_n - someip.header_len != int(${fb}_len) {'
			glue << '\t\t\t\t\trx_drops++'
			glue << '\t\t\t\t\tcontinue'
			glue << '\t\t\t\t}'
			glue << '\t\t\t\tmut pay_rx_${fb} := [64]u8{} // com.max_pdu'
			glue << '\t\t\t\tfor i in 0 .. int(${fb}_len) {'
			glue << '\t\t\t\t\tpay_rx_${fb}[i] = rx_buf[someip.header_len + i]'
			glue << '\t\t\t\t}'
			// the trailer check gates the unpack, as the CAN bridge gates decode: ok and lost
			// are usable (loss flagged, data valid); a wrong CRC/id is a counted drop
			glue << eth_rx_accept(m, fr, '\t\t\t\t', 'rx_drops++', '')
		}
		glue << '\t\t\t} else {'
		glue << '\t\t\t\trx_drops++ // an event id the config does not route'
		glue << '\t\t\t}'
		glue << '\t\t}'
		for fr in rx_frames {
			glue << eth_rx_expiry(m, fr, '\t\t')
		}
		for fr in rx_frames {
			fb := snake(fr.name)
			glue << '\t\tif got_${fb} {'
			for s in fr.signals {
				ss := snake(s)
				tr := (m.sig_of[s] or { SigInfo{} }).transport
				glue << '\t\t\tosal.${publish_fn(tr)}(${ss}_ch, &rxs_${ss}, u8(sizeof(rxs_${ss})))'
			}
			glue << '\t\t}'
		}
		glue << '\t\tif rx_drops != rx_drops_told && now - rx_told_at > 1_000_000 {'
		glue << "\t\t\teprintln('someip: rx drops counted') // no count in the text: -gc none forbids interpolation"
		glue << '\t\t\trx_drops_told = rx_drops'
		glue << '\t\t\trx_told_at = now'
		glue << '\t\t}'
	}
	for fr in tx_frames {
		fb := snake(fr.name)
		mut params := []string{}
		glue << '\t\tmut pay_${fb} := [64]u8{} // com.max_pdu'
		glue << '\t\tmut any_${fb} := false'
		for s in fr.signals {
			ss := snake(s)
			// the acquire must match the signal's configured transport — the
			// FB publishes into that pool, not necessarily the double-buffer
			tr := (m.sig_of[s] or { SigInfo{} }).transport
			glue << '\t\tmut s_${ss} := sig.${s}{}'
			glue << '\t\tif osal.${acquire_fn(tr)}(${ss}_ch, &s_${ss}, u8(sizeof(s_${ss}))) {'
			glue << '\t\t\tany_${fb} = true'
			glue << '\t\t}'
			params << 's_${ss}'
		}
		glue << '\t\t${fb}_pack(mut pay_${fb}, ${params.join(', ')})'
		glue << '\t\tif any_${fb} && tx_${fb}_st.should_send(now, pay_${fb}, ${fb}_len) {'
		glue << '\t\t\tpre_${fb} := pay_${fb} // pre-E2E payload, for change detection'
		if fr.e2e_on {
			glue << '\t\t\te2e_save_${fb} := e2e_tx_${fb}'
			glue << '\t\t\te2e_tx_${fb}.protect(&pay_${fb}[0], int(${fb}_len), ${fb}_e2e_id, ${fb}_e2e_crc, ${fb}_e2e_ctr)'
		}
		glue << '\t\t\th_${fb} := someip.notification(someip_service, ${fb}_event_id, someip_version, int(${fb}_len))'
		glue << '\t\t\tn_${fb} := someip.encode(h_${fb}, &dgram[0])'
		glue << '\t\t\tfor i in 0 .. int(${fb}_len) {'
		glue << '\t\t\t\tdgram[n_${fb} + i] = pay_${fb}[i]'
		glue << '\t\t\t}'
		glue << '\t\t\tif sock.send(someip_peer_ip, someip_peer_port, &dgram[0], n_${fb} + int(${fb}_len)) {'
		glue << '\t\t\t\ttx_${fb}_st.mark_sent(now, pre_${fb}, ${fb}_len)'
		if fr.e2e_on {
			glue << '\t\t\t} else {'
			glue << '\t\t\t\te2e_tx_${fb} = e2e_save_${fb} // unsent: keep the counter honest'
		}
		glue << '\t\t\t}'
		glue << '\t\t}'
	}
	glue << '\t\tosal.sleep_us(1000)'
	glue << '\t}'
	glue << '}'
	return glue
}

// bus_hosts_modules: does this bus carry PLATFORM MODULES rather than signals? The comm thread
// is where trace and telemetry live (docs/com-modules.md), so a dedicated diagnostic bus needs a
// partition to own it even though no [[signal]] mentions it.
//
// Without this a signal-less trace bus was dropped from the bridge set entirely, so it never
// became a run() parameter and nothing owned the channel — which is how examples/trace_comm and
// examples/trace_multicore ended up with a run() their own main.v could not call (#191). The
// config still declared cmd/rsp/record ids; they simply went nowhere.
// `trace_host` = the single-partition host runner is already the trace bus's owner, so that bus
// needs no bridge; generating one anyway produced a partition nothing spawns.
fn bus_hosts_modules(m Model, bname string, trace_host bool) bool {
	if trace_host || m.target.on {
		// TARGET builds own their bus from the superloop / comm thread, and their generated file
		// imports osal only on the host path — a bridge emitted there does not even compile
		// (examples/h735_app is exactly this shape: [telemetry] + [trace] on a signal-less bus).
		return false
	}
	tbus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
	return (m.trace.on && tbus == bname) || (m.telem.on && m.telem.bus == bname)
}

fn emit_bridges(m Model, comm_thread_on bool, trace_host bool, producers []Producer, tctx TraceHostCtx) ([]string, []string, map[string][]string) {
	mut glue := []string{}
	mut bus_names := []string{}
	mut bus_dests := map[string][]string{}
	// per-DBC-message extended-id flag: every generated rx dispatch predicate must match
	// rx.ext too, or a standard frame could satisfy an extended route (or vice versa) that
	// shares the numeric id — the FDCAN backend now delivers both widths.
	mut msg_ext := map[string]bool{}
	for _, si in m.sig_of {
		if si.external && si.dbc_msg != '' {
			msg_ext[si.dbc_msg] = si.dbc_ext
		}
	}
	for bname, _ in m.buses {
		if comm_thread_on {
			continue
		}
		// an eth bus gets no CAN bridge: no can.Channel, no DBC codec — its tx
		// loop is the someip/UDP rung (docs/someip.md); this rung emits the
		// frame table + derived-layout codec only (emit_eth_codec)
		if m.bus_kind[bname] or { 'can' } == 'eth' {
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
		// m.routes that ORIGINATE on this bus, and the distinct destination m.buses.
		// `dests` (a borrowed destination channel) exists only for SAME-CORE routes: a
		// CROSSING signal route (buses on different cores, REQ-TOPO-010) never shares a
		// channel — its value rides an IOC channel and the DESTINATION bridge transmits.
		mut my_routes := []Route{}
		mut dests := []string{}
		for r in m.routes {
			if r.from_bus == bname {
				my_routes << r
				if !r.crossing(m.bus_core) && r.to_bus !in dests {
					dests << r.to_bus
				}
			}
		}
		dests.sort()
		// crossing routes TERMINATING here: this bridge acquires the routed value and
		// composes/sends the destination frame on its OWN channel.
		mut in_routes := []Route{}
		for r in m.routes {
			if r.signal != '' && r.to_bus == bname && r.crossing(m.bus_core) {
				in_routes << r
			}
		}
		// A bus with no signals of its own may still HOST PLATFORM MODULES: the comm thread is
		// where trace/telemetry live (docs/com-modules.md), so a dedicated diagnostic bus needs
		// a partition to own it. Skipping it silently is what broke examples/trace_comm and
		// examples/trace_multicore (#191): the trace bus vanished from run(), taking the dump
		// path with it, and the config still declared cmd/rsp/record ids that went nowhere.
		if tctx.on() && bname == tctx.trace_bus {
			// P3b: the dedicated trace bus is a run() PARAMETER (so main.v's call is unchanged
			// and the channel is opened exactly once) but gets no partition — the bridge owner
			// drains it, serves the module on it, and would otherwise race a second reader.
			bus_names << bname
			bus_dests[bname] = dests
			continue
		}
		if rx_by_msg.len == 0 && tx_by_msg.len == 0 && conns.len == 0 && my_routes.len == 0
			&& in_routes.len == 0 && !bus_hosts_modules(m, bname, trace_host) {
			continue
		}
		bus_names << bname
		bus_dests[bname] = dests

		// SIGNAL routes, two roles per bridge (P2a.2b + the crossing extension):
		//   rx_routes  — source side (from == this bus): decode on rx; same-core stores the
		//                value+freshness locally, a crossing PUBLISHES it (one f64) instead.
		//   sig_routes — producer side (same-core from here, or crossing TO here): holds the
		//                value+freshness state, composes the WHOLE destination frame and
		//                re-emits it per the dest frame's cadence + TX mode. dst_frames = one
		//                representative Route per distinct (to_bus, to_frame).
		mut rx_routes := []Route{}
		mut sig_routes := []Route{}
		for r in my_routes {
			if r.signal != '' {
				rx_routes << r
				if !r.crossing(m.bus_core) {
					sig_routes << r
				}
			}
		}
		sig_routes << in_routes
		mut dst_frames := []Route{}
		mut seen_df := map[string]bool{}
		for r in sig_routes {
			dk := '${snake(r.to_bus)}_${snake(r.to_frame)}'
			if dk !in seen_df {
				seen_df[dk] = true
				dst_frames << r
			}
		}

		// io fn needs a timestamp to gate tx, monitor rx deadlines, or pace ISO-TP
		mut uses_now := tx_by_msg.len > 0 || conns.len > 0 || sig_routes.len > 0
		for msg, _ in rx_by_msg {
			if has_deadline(m, msg, bname) {
				uses_now = true
			}
		}

		glue << ''
		glue << 'struct Bridge_${bb}_state {'
		glue << 'mut:'
		glue << '\tchan can.Channel'
		for msg, _ in tx_by_msg {
			glue << '\ttx_${msg}_st com.TxState'
			if m.frames.e2e_here(msg, bname) {
				glue << '\te2e_tx_${msg} e2e.TxState'
			}
			if m.frames.secoc_here(msg, bname) {
				glue << '\tsecoc_key_${msg} secoc.Key'
				glue << '\tsecoc_tx_${msg} secoc.TxState'
			}
		}
		for msg, _ in rx_by_msg {
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				glue << '\trx_${msg}_st com.RxState'
			}
			if m.frames.e2e_here(msg, bname) {
				glue << '\te2e_rx_${msg} e2e.RxState'
				if lost_expr(m, msg, bname, conns.len > 0).contains('e2e_hidden') {
					glue << '\te2e_hidden_${msg} u32 // lost frames counted while 0x28 had rx off'
					glue << '\te2e_quiet_${msg} bool // 0x28 had rx off since the last fresh frame'
				}
			}
			if m.frames.secoc_here(msg, bname) {
				glue << '\tsecoc_key_${msg} secoc.Key'
				glue << '\tsecoc_rx_${msg} secoc.RxState'
			}
		}
		for c in conns {
			tp := snake(c.name)
			glue << '\tconn_${tp} diag.Connection // the node\'s diagnostic server on its ISO-TP connection'
			if m.faults.len > 0 {
				glue << '\tfmem fault.Memory // the node\'s fault memory: this bridge is its one writer (D2)'
				glue << '\tfcycle_on bool // the operation-cycle signal as last seen'
				for src in fault_sources(m) {
					glue << '\tfsrc_${snake(src)} sig.RxStatus // ${src}\'s latest published status (signal-status faults)'
				}
				for i, f in m.faults {
					if f.signal != '' {
						glue << '\tsdeb_${i} fault.Debounce // ${f.name}: ${f.signal} ${f.on}, debounced here'
						glue << '\tsev_${i} bool // a publication stepped it since the last pass top: skip the level step'
						if f.on == 'lost' {
							lt := (m.sig_of[f.signal] or { SigInfo{} }).lost_type
							glue << '\tslost_${i} ${lt} // the lost-frame count last seen (wrapping)'
						}
					}
				}
				for fb in fault_fbs(m) {
					glue << '\tfrep_${snake(fb)} fault.Reports // from ${fb}\'s thread'
					glue << '\tfctl_${snake(fb)} fault.Control // to ${fb}\'s thread'
				}
			}
			if security_levels(m.dids) != 0 {
				glue << '\tsa_${tp} uds.ReferenceSecurity // 0x27 on the host: the SIM key (not a secret, decision D5)'
			}
		}
		if conns.len > 0 && rx_off_latched(m, rx_by_msg.keys(), bname) {
			glue << '\tdiag_rx_was_off bool // 0x28 had rx off (any sampling since the last restart): restart the deadlines on return'
		}
		for d in dests {
			glue << '\troute_${snake(d)} can.Channel // gateway: forward to ${d}'
		}
		// SIGNAL-route producer state: the latest physical value + freshness stamp per
		// routed signal, and one TxState per destination frame (its cadence + TX mode).
		for r in sig_routes {
			rk := route_field(r)
			glue << '\t${rk}_v f64 // routed physical value'
			glue << '\t${rk}_fresh u64 // rx timestamp (0 = never received)'
		}
		// source-route VERIFY state: a PROTECTED source frame is checked (E2E/SecOC)
		// before its value is decoded. One RxState per distinct source frame; a frame
		// also read by a normal signal (in rx_by_msg) is rejected in gen.v so the replay
		// counter is never double-advanced, so it never needs a second state here.
		mut src_verify_seen := map[string]bool{}
		for r in rx_routes { // verify state lives at the SOURCE (rx) side, crossing or not
			frof := snake(r.from_frame)
			if frof in src_verify_seen || frof in rx_by_msg {
				continue
			}
			// a COMPOSED source (both protections) needs BOTH verifier states — the
			// verify emission nests E2E under SecOC (REQ-E2E-004), and an else-if here
			// generated references to an undeclared field (codex #218)
			if m.frames.e2e_here(frof, r.from_bus) {
				src_verify_seen[frof] = true
				glue << '\te2e_rx_${frof} e2e.RxState'
			}
			if m.frames.secoc_here(frof, r.from_bus) {
				src_verify_seen[frof] = true
				glue << '\tsecoc_key_${frof} secoc.Key'
				glue << '\tsecoc_rx_${frof} secoc.RxState'
			}
		}
		for r in dst_frames {
			dk := '${snake(r.to_bus)}_${snake(r.to_frame)}'
			tof := snake(r.to_frame) // m.frames is keyed by snake(frame name)
			glue << '\trt_tx_${dk} com.TxState'
			// a PROTECTED destination frame: the producer re-protects the composed frame
			// with a fresh CRC/MAC before send.
			if m.frames.e2e_here(tof, r.to_bus) {
				glue << '\te2e_tx_${dk} e2e.TxState'
			}
			if m.frames.secoc_here(tof, r.to_bus) {
				glue << '\tsecoc_key_${dk} secoc.Key'
				glue << '\tsecoc_tx_${dk} secoc.TxState'
			}
		}
		// RAW frame-route pending slot: a forward that the destination TX could not
		// accept yet (tx_ready false / send failed) is held here and retried next tick.
		for r in my_routes {
			if r.signal == '' {
				rf := raw_field(r)
				glue << '\t${rf} can.Frame // held forward awaiting destination tx-ready'
				glue << '\t${rf}_set bool'
			}
		}
		glue << '}'
		for c in conns {
			glue << did_refresh_fn(m, snake(c.name))
		}
		glue << ''
		// A module-host bus has no signal work, so it gets no tick handler at all — see the
		// drain loop below. An empty one compiled to `mut st := …` and nothing else, which is a
		// warning on every build of both trace examples.
		module_host := rx_by_msg.len == 0 && tx_by_msg.len == 0 && conns.len == 0
			&& my_routes.len == 0 && in_routes.len == 0
		if !module_host {
		glue << 'fn io_${bb}_10ms(ctx voidptr) {'
		glue << '\tmut st := unsafe { &Bridge_${bb}_state(ctx) }'
		if uses_now {
			glue << '\tnow := osal.now_us()'
		}
		// RETRY a raw forward HELD from a previous tick — tx-ready gated (REQ-TOPO-010).
		// This never blocks the source receive path: ingress keeps draining below, so a
		// congested destination can't stall unrelated raw routes / local COM / ISO-TP or
		// overrun the source RX FIFO. A raw route carries a CYCLIC frame (the contract
		// requires cycle_ms > 0 on both buses), so if a newer PDU arrives while one is
		// still held, FRESHEST-wins — that is rate adaptation of a periodic frame (the
		// same sampling P2a.2b does), not data loss.
		for r in my_routes {
			if r.signal == '' {
				rf := raw_field(r)
				dch := 'st.route_${snake(r.to_bus)}'
				glue << '\tif st.${rf}_set && ${dch}.tx_ready() && ${dch}.send(st.${rf}) {'
				glue << '\t\tst.${rf}_set = false'
				glue << '\t}'
			}
		}
		if conns.len > 0 {
			// CommunicationControl (0x28): normal application messages on this bus stop being
			// sent / decoded while any of its diagnostic servers says so. Diagnostic traffic itself
			// is never gated (docs/diagnostics.md §3.1).
			// Housekeeping FIRST (comm/diag), so the receive gate below and the functional path in
			// the drain see this instant's state. On the host there is no platform reset, so an
			// answered ECUReset returns the DIAGNOSTIC state to power-on (docs/diagnostics.md §3.1).
			for c in conns {
				glue << '\tst.conn_${snake(c.name)}.housekeep(now)'
			}
			glue << rx_gate_sample(m, conns, rx_by_msg.keys(), bname, '\t', true)
			glue << fault_pass_lines(m)
		}
		if rx_by_msg.len > 0 || conns.len > 0 || my_routes.len > 0 {
			glue << '\tmut rx := can.Frame{}'
			glue << '\tfor st.chan.recv(mut rx) {'
			for r in my_routes {
				if r.signal != '' {
					// SIGNAL route (P2a.2b): DECODE the routed signal from the source frame to
					// its physical value and STORE it (with a freshness stamp). The producer
					// below composes + re-emits the destination frame per its own cadence. Require
					// rx.len == source DLC so the decode never reads stale bytes. If the SOURCE
					// frame is E2E/SecOC-protected, VERIFY it first — decode only on a usable
					// result, so a bad/replayed/tampered frame leaves the value stale (the
					// freshness deadline then suppresses the destination). gen.v guarantees a
					// protected source is routed by exactly one route (one verify per frame).
					rk := route_field(r)
					frof := snake(r.from_frame)
					s_e2e := m.frames.e2e_here(frof, r.from_bus)
					s_secoc := m.frames.secoc_here(frof, r.from_bus)
					glue << '\t\tif rx.id == u32(0x${r.from_id.hex()}) && rx.len == ${r.from_dlc} && rx.ext == ${r.from_ext} {'
					mut ind := '\t\t\t'
					if s_secoc {
						glue << '\t\t\tif st.secoc_rx_${frof}.verify(&st.secoc_key_${frof}, &rx.data[0], int(${r.from_dlc}), u16(0x${(m.frames.secoc_id[frof] or {
							0
						}).hex()}), ${m.frames.secoc_fresh[frof] or { 0 }}, ${m.frames.secoc_mac[frof] or { 0 }}, ${m.frames.secoc_maclen[frof] or {
							0
						}}).usable() {'
						ind = '\t\t\t\t'
						if s_e2e {
							// composed source: authentic first, then E2E with SecOC's bytes
							// excluded (REQ-E2E-004) — the E2E repeat/loss verdict must not
							// be masked by the MAC passing
							glue << '${ind}if st.e2e_rx_${frof}.check_ex(&rx.data[0], int(${r.from_dlc}), u16(0x${(m.frames.e2e_id[frof] or {
								0
							}).hex()}), ${m.frames.e2e_crc[frof] or { 0 }}, ${m.frames.e2e_ctr[frof] or { 0 }}, ${m.frames.secoc_fresh[frof] or { 0 }}, 1, ${m.frames.secoc_mac[frof] or { 0 }}, ${m.frames.secoc_maclen[frof] or { 0 }}).usable() {'
							ind = '\t\t\t\t\t'
						}
					} else if s_e2e {
						glue << '\t\t\tif st.e2e_rx_${frof}.check(&rx.data[0], int(${r.from_dlc}), u16(0x${(m.frames.e2e_id[frof] or {
							0
						}).hex()}), ${m.frames.e2e_crc[frof] or { 0 }}, ${m.frames.e2e_ctr[frof] or { 0 }}).usable() {'
						ind = '\t\t\t\t'
					}
					if r.crossing(m.bus_core) {
						// crossing (REQ-TOPO-010): the value leaves this core here — one f64
						// over the route's IOC channel; the DESTINATION bridge stamps its own
						// freshness on acquire, so no clock ever crosses the boundary.
						glue << '${ind}xr_${rk} := ${frof}_${snake(r.signal)}_phys(rx.data)'
						glue << '${ind}osal.ioc_publish(${r.xr_ch()}, &xr_${rk}, 8) // triple: tear-free when rx bursts lap the 10ms consumer (codex #200)'
					} else {
						glue << '${ind}st.${rk}_v = ${frof}_${snake(r.signal)}_phys(rx.data)'
						glue << '${ind}st.${rk}_fresh = now'
					}
					if s_e2e || s_secoc {
						glue << '\t\t\t}'
						if s_e2e && s_secoc {
							glue << '\t\t\t}' // the nested composed E2E check (REQ-E2E-004)
						}
					}
					glue << '\t\t}'
					continue
				}
				// raw-PDU gateway: forward the frame to another bus, unchanged (optionally
				// remapping the id), without decoding it to signals. Require rx.len == the
				// contracted DLC (like the signal-route + COM rx paths) so a short/oversized
				// frame at the routed id is NOT forwarded with stale trailing bytes. Each
				// destination route is INDEPENDENT (fan-out delivers to whichever dests are
				// ready). The send is tx-ready gated; if the destination can't accept it now,
				// hold the FRESHEST PDU in this route's slot for retry (freshest-wins on a
				// cyclic frame = rate adaptation) — draining never stops, so ingress flows.
				rf := raw_field(r)
				dch := 'st.route_${snake(r.to_bus)}'
				glue << '\t\tif rx.id == u32(0x${r.from_id.hex()}) && rx.len == ${r.from_dlc} && rx.ext == ${r.from_ext} {'
				glue << '\t\t\tmut fwd := rx'
				if r.to_id != r.from_id {
					glue << '\t\t\tfwd.id = u32(0x${r.to_id.hex()})'
				}
				glue << '\t\t\tif ${dch}.tx_ready() && ${dch}.send(fwd) {'
				glue << '\t\t\t\tst.${rf}_set = false // newer PDU went out; drop any stale held one (freshest-wins)'
				glue << '\t\t\t} else {'
				glue << '\t\t\t\tst.${rf} = fwd'
				glue << '\t\t\t\tst.${rf}_set = true'
				glue << '\t\t\t}'
				glue << '\t\t}'
			}
			for msg, list in rx_by_msg {
				// require the received length to match the PDU DLC — recv copies only
				// the actual bytes into the reused frame, so a short same-id frame
				// would otherwise be decoded over stale trailing bytes.
				glue << '\t\tif rx.id == ${msg}_id && rx.len == ${msg}_dlc && rx.ext == ${msg_ext[msg]} {'
				e2e := m.frames.e2e_here(msg, bname)
				secoc := m.frames.secoc_here(msg, bname)
				// protected frames are decoded only if the check passes. A frame that FAILS it — an
				// E2E CRC error, or any SecOC failure — publishes status `integrity` to the signals that
				// carry one (docs/diagnostics.md §3.2); an E2E REPEAT is a duplicate, not a fault, and
				// publishes nothing (a stuck sender then reaches `timeout` through the deadline).
				// 0x28 gates only what the application SEES: the checks themselves run on every frame,
				// so SecOC freshness and the E2E counter keep tracking the sender and the first frame
				// after rx is re-enabled is not judged a replay or a loss burst.
				lost := lost_expr(m, msg, bname, conns.len > 0)
				gate := if conns.len > 0 { 'diag_rx_ok' } else { '' }
				mut ind := '\t\t\t'
				if secoc {
					glue << '${ind}if st.secoc_rx_${msg}.verify(&st.secoc_key_${msg}, &rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.secoc_id[msg] or {
						0
					}).hex()}), ${m.frames.secoc_fresh[msg] or { 0 }}, ${m.frames.secoc_mac[msg] or { 0 }}, ${m.frames.secoc_maclen[msg] or {
						0
					}}).usable() {'
					ind += '\t'
				}
				if e2e {
					// composed frame: only an AUTHENTIC message reaches the E2E check (REQ-E2E-004
					// order), and the check excludes SecOC's bytes. STATE COUPLING: secoc's freshness
					// window has already advanced by the time E2E rejects (verify precedes).
					chk := if secoc {
						'check_ex(&rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or { 0 }).hex()}), ${m.frames.e2e_crc[msg] or { 0 }}, ${m.frames.e2e_ctr[msg] or { 0 }}, ${m.frames.secoc_fresh[msg] or { 0 }}, 1, ${m.frames.secoc_mac[msg] or { 0 }}, ${m.frames.secoc_maclen[msg] or { 0 }})'
					} else {
						'check(&rx.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or { 0 }).hex()}), ${m.frames.e2e_crc[msg] or { 0 }}, ${m.frames.e2e_ctr[msg] or { 0 }})'
					}
					hide := lost != '' && conns.len > 0
					if hide {
						glue << '${ind}lf_${msg} := st.e2e_rx_${msg}.lost_frames'
					}
					glue << '${ind}e2e_${msg} := st.e2e_rx_${msg}.${chk}'
					if hide {
						// frames missed while 0x28 has reception off were COMMANDED silence, not loss:
						// the sequence state keeps tracking them, but the FB never sees them counted —
						// including the gap the first fresh frame after re-enable closes, which spans
						// the silence (rx_gate_sample marks e2e_quiet whenever it finds rx off)
						glue << '${ind}if st.e2e_quiet_${msg} { // set by every sampling that found rx off'
						glue << '${ind}\tst.e2e_hidden_${msg} += st.e2e_rx_${msg}.lost_frames - lf_${msg}'
						glue << '${ind}}'
						glue << '${ind}if diag_rx_ok && e2e_${msg}.usable() {'
						glue << '${ind}\tst.e2e_quiet_${msg} = false'
						glue << '${ind}}'
					}
					// the decision is comm/e2e's RxState.receive_ex (the SOME/IP path's rule too): a
					// usable frame refreshes the timeout — protection-level state, like the counter,
					// even while 0x28 has rx off — and reads late when the timeout ran out unseen; a
					// corrupt one restarts only a timeout that fired. Suspended while a 0x28 silence
					// is still latched: its restart (after the drain) has not run yet, and the
					// deadline it would test is the stale pre-silence one
					// every received E2E frame has a timeout (validate_e2e_timeouts), so the latch
					// matters wherever a diagnostic connection can switch reception off
					susp := if conns.len > 0 { 'st.diag_rx_was_off' } else { 'false' }
					glue << '${ind}v_${msg} := st.e2e_rx_${msg}.receive_ex(now, e2e_${msg}, ${susp})'
					glue << '${ind}if v_${msg} == .ok || v_${msg} == .timeout {'
					ind += '\t'
					if e2e_timeout(m, msg, bname) > 0 {
						glue << '${ind}late_${msg} := v_${msg} == .timeout'
					}
				}
				if gate != '' {
					glue << '${ind}if ${gate} {'
					ind += '\t'
				}
				if e2e && e2e_timeout(m, msg, bname) > 0 {
					glue << '${ind}if late_${msg} {'
					for sname in list {
						si := m.sig_of[sname] or { continue }
						fld := snake(sname)
						glue << '${ind}\tmut ${fld} := sig.${sname}{ ${rx_status_fields(si, '.timeout', lost)[2..]} }'
						glue << '${ind}\tosal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
					}
					glue << rx_group_hooks(m, list, ind + '\t')
					glue << '${ind}} else {'
					ind += '\t'
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
					glue << '${ind}mut ${fld} := sig.${sname}{ ${valassign}${rx_status_fields(si, '.ok', lost)} }'
					glue << '${ind}osal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
				}
				glue << rx_group_hooks(m, list, ind)
				if e2e && e2e_timeout(m, msg, bname) > 0 {
					ind = ind[1..]
					glue << '${ind}}'
				}
				if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
					glue << '${ind}st.rx_${msg}_st.on_receive(now)'
				}
				if gate != '' {
					ind = ind[1..]
					glue << '${ind}}'
				}
				if e2e {
					ind = ind[1..]
					glue << '${ind}} else if v_${msg} == .integrity {'
					glue << rx_integrity(m, list, msg, lost, gate, ind + '\t', false)
					glue << '${ind}}'
				}
				if secoc {
					ind = ind[1..]
					glue << '${ind}} else {'
					glue << rx_integrity(m, list, msg, lost, gate, ind + '\t', true)
					glue << '${ind}}'
				}
				glue << '\t\t}'
			}
			for c in conns {
				// a completed request is served BEFORE the frames queued behind it are judged: a 0x28
				// in the FIFO must gate the application frames that follow it, not only the next
				// pass's. A functional request is served on arrival, so the receive gate is re-sampled
				// right after it.
				glue << '\t\tmatch st.conn_${snake(c.name)}.on_frame(now, &rx) {'
				glue << '\t\t\t.request { break }'
				if c.functional_id != 0 {
					glue << '\t\t\t.served {'
					glue << rx_gate_sample(m, conns, rx_by_msg.keys(), bname, '\t\t\t\t', false)
					glue << '\t\t\t}'
				}
				glue << '\t\t\telse {}'
				glue << '\t\t}'
			}
			glue << '\t}'
			// Serve the reassembled request, then send the answer — tx_ready-gated, so a response
			// burst never overruns the Tx FIFO or blocks: at most a FIFO's worth per pass.
			for c in conns {
				tp := snake(c.name)
				glue << '\tst.conn_${tp}.serve()'
				glue << '\tmut cf_${tp} := can.Frame{}'
				glue << '\tfor st.chan.tx_ready() && st.conn_${tp}.produce(now, mut cf_${tp}) {'
				glue << '\t\tif !st.chan.send(cf_${tp}) {'
				glue << '\t\t\tst.conn_${tp}.abort_tx()'
				glue << '\t\t\tbreak'
				glue << '\t\t}'
				glue << '\t}'
			}
		}
		// rx deadline crossed -> publish invalid (valid=false) signals, once. While 0x28 has rx
		// off, silence is commanded, not a fault: no deadline fires, and every deadline restarts
		// when rx comes back (below), so a diagnostic command never fakes a comms timeout.
		if conns.len > 0 && rx_off_latched(m, rx_by_msg.keys(), bname) {
			// re-sampled AFTER this pass's requests were served: a 0x28 disabling rx now suspends
			// the deadlines before any of them can fire
			glue << rx_gate_sample(m, conns, rx_by_msg.keys(), bname, '\t', false)
			glue << '\tif diag_rx_ok && st.diag_rx_was_off {'
			for msg, _ in rx_by_msg {
				if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
					glue << '\t\tst.rx_${msg}_st.on_receive(now)'
				}
				if e2e_timeout(m, msg, bname) > 0 {
					glue << '\t\tst.e2e_rx_${msg}.arm(now)'
				}
			}
			glue << '\t}'
			glue << '\tst.diag_rx_was_off = !diag_rx_ok'
		}
		// Two deadlines publish the same `timeout`: the QM COM one (REQ-COM-005) and the E2E-owned
		// one (REQ-E2E-002) — no VALID message for its period, so a stuck or corrupt-only sender
		// runs it out too. Either may be configured alone; both suspend under 0x28 alike.
		for msg, list in rx_by_msg {
			dl_gate := if conns.len > 0 { 'diag_rx_ok && ' } else { '' }
			mut expiries := []string{}
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				expiries << 'st.rx_${msg}_st.expired(now)'
			}
			if e2e_timeout(m, msg, bname) > 0 {
				expiries << 'st.e2e_rx_${msg}.expired(now)'
			}
			for exp in expiries {
				glue << '\tif ${dl_gate}${exp} {'
				lost := lost_expr(m, msg, bname, conns.len > 0)
				for sname in list {
					si := m.sig_of[sname] or { continue }
					fld := snake(sname)
					sf := rx_status_fields(si, '.timeout', lost)
					glue << '\t\tmut ${fld} := sig.${sname}{${if sf == '' { '' } else { ' ' + sf[2..] + ' ' }}}'
					glue << '\t\tosal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
				}
				glue << rx_group_hooks(m, list, '\t\t')
				glue << '\t}'
			}
		}
		if conns.len > 0 {
			// evaluated AFTER the requests of this pass were served, so a 0x28 answered just
			// above already gates this pass's application frames
			glue << '\tdiag_tx_ok := ${conns.map('st.conn_${snake(it.name)}.server.tx_enabled()').join(' && ')}'
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
			e2e_here := m.frames.e2e_here(msg, bname)
			secoc_here := m.frames.secoc_here(msg, bname)
			needs_pre := e2e_here || secoc_here
			tx_gate := if conns.len > 0 { ' && diag_tx_ok' } else { '' }
			glue << '\tif tx_${msg}_any${tx_gate} && st.chan.tx_ready() && st.tx_${msg}_st.should_send(now, tx_${msg}.data, ${msg}_dlc) {'
			if needs_pre {
				glue << '\t\ttx_${msg}_pre := tx_${msg}.data // pre-E2E/SecOC payload, for change detection'
			}
			if e2e_here {
				// snapshot the alive counter so a rejected send can rewind it (protect()
				// advances the counter as a side effect); then stamp CRC + counter after the
				// change decision (so the counter doesn't make every frame look "changed").
				// With SecOC on the same frame, the CRC must EXCLUDE the freshness/MAC
				// bytes SecOC stamps after this call (REQ-E2E-004) — protect_ex windows.
				glue << '\t\te2e_save_${msg} := st.e2e_tx_${msg}'
				if secoc_here {
					glue << '\t\tst.e2e_tx_${msg}.protect_ex(&tx_${msg}.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or {
						0
					}).hex()}), ${m.frames.e2e_crc[msg] or { 0 }}, ${m.frames.e2e_ctr[msg] or { 0 }}, ${m.frames.secoc_fresh[msg] or { 0 }}, 1, ${m.frames.secoc_mac[msg] or { 0 }}, ${m.frames.secoc_maclen[msg] or { 0 }})'
				} else {
					glue << '\t\tst.e2e_tx_${msg}.protect(&tx_${msg}.data[0], int(${msg}_dlc), u16(0x${(m.frames.e2e_id[msg] or {
						0
					}).hex()}), ${m.frames.e2e_crc[msg] or { 0 }}, ${m.frames.e2e_ctr[msg] or { 0 }})'
				}
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
		// CROSSING intake (REQ-TOPO-010): a routed value arriving from another core's comm
		// owner. Freshness is stamped HERE, from the transport's fresh flag — never a
		// timestamp carried across cores (their clocks are not comparable; the trace
		// correlation work exists precisely because of that).
		for r in in_routes {
			rk := route_field(r)
			glue << '\tmut xr_in_${rk} := f64(0)'
			glue << '\tif osal.ioc_acquire_fresh(${r.xr_ch()}, &xr_in_${rk}, 8) { // fresh = NEW publication only — ever-written freshness never trips the staleness deadline (codex #200)'
			glue << '\t\tst.${rk}_v = xr_in_${rk}'
			glue << '\t\tst.${rk}_fresh = now'
			glue << '\t}'
		}
		// SIGNAL-route producers (P2a.2b): compose each destination frame from its
		// routed signals and re-emit per the frame's own cadence + TX mode (rate
		// adaptation), gated on the dest channel's tx_ready. A signal not yet received
		// (fresh == 0) or stale beyond its source deadline suppresses the frame, so a
		// downstream receiver detects the loss instead of seeing stale-as-fresh. A
		// crossing route's producer runs on the DESTINATION bridge and sends on its
		// OWN channel; a same-core route's producer sends on the borrowed dest channel.
		for r in dst_frames {
			dk := '${snake(r.to_bus)}_${snake(r.to_frame)}'
			glue << '\tmut rf_${dk} := can.Frame{'
			glue << '\t\tid:  u32(0x${r.to_id.hex()})'
			glue << '\t\tlen: ${r.to_dlc}'
			glue << '\t\text: ${r.to_ext}' // re-encode into a 29-bit dest frame keeps its id width
			glue << '\t}'
			glue << '\tmut rf_${dk}_ok := true'
			for r2 in sig_routes {
				if r2.to_bus != r.to_bus || r2.to_frame != r.to_frame {
					continue
				}
				rk := route_field(r2)
				glue << '\t${snake(r2.to_frame)}_${snake(r2.signal)}_set(mut rf_${dk}.data, st.${rk}_v)'
				// freshness: suppress the frame if the source was never received, or is stale
				// beyond its deadline — the source frame's authored [[frame]].rx.timeout_ms if
				// present, else 3x its DBC cadence (0 = no deadline, so only never-received).
				frof := snake(r2.from_frame)
				// an authored [[frame]].rx with no timeout_ms inserts 0; treat 0 as absent and
				// fall back to 3x the DBC cadence (0 = no deadline info at all).
				// the E2E-owned timeout is an authored deadline for the source too — and the SHORTER
				// of the two wins, so either monitor stops forwarding a dead sender's value
				com_to := m.frames.rx_timeout_us[frof] or { 0 }
				e2e_to := e2e_timeout(m, frof, r2.from_bus)
				authored_to := if com_to > 0 && e2e_to > 0 {
					if com_to < e2e_to { com_to } else { e2e_to }
				} else if com_to > 0 {
					com_to
				} else {
					e2e_to
				}
				timeout := if authored_to > 0 {
					authored_to
				} else if r2.from_cyc > 0 {
					r2.from_cyc * 3000
				} else {
					0
				}
				if timeout > 0 {
					glue << '\tif st.${rk}_fresh == 0 || now - st.${rk}_fresh > u64(${timeout}) {'
					glue << '\t\trf_${dk}_ok = false'
					glue << '\t}'
				} else {
					glue << '\tif st.${rk}_fresh == 0 {'
					glue << '\t\trf_${dk}_ok = false'
					glue << '\t}'
				}
			}
			// re-protect the composed dest frame (fresh E2E CRC/counter or SecOC MAC) AFTER
			// the change decision — like a normal COM producer — so the counter doesn't make
			// every frame look "changed", and rewind it if a tx_ready-passed send is rejected
			// (keeps the counter honest so the receiver sees no skip). Source frames are
			// unprotected (guarded), so this is pure destination re-protection.
			rtof := snake(r.to_frame)
			r_e2e := m.frames.e2e_here(rtof, r.to_bus)
			r_secoc := m.frames.secoc_here(rtof, r.to_bus)
			r_pre := r_e2e || r_secoc
			// a crossing route's producer runs on the destination bridge — its own channel
			dch := if r.crossing(m.bus_core) { 'st.chan' } else { 'st.route_${snake(r.to_bus)}' }
			glue << '\tif rf_${dk}_ok && ${dch}.tx_ready() && st.rt_tx_${dk}.should_send(now, rf_${dk}.data, ${r.to_dlc}) {'
			if r_pre {
				glue << '\t\trf_${dk}_pre := rf_${dk}.data // pre-protect payload, for mark_sent'
			}
			if r_e2e {
				glue << '\t\te2e_save_${dk} := st.e2e_tx_${dk}'
				if r_secoc {
					// composed destination: E2E excludes the SecOC bytes stamped next
					glue << '\t\tst.e2e_tx_${dk}.protect_ex(&rf_${dk}.data[0], int(${r.to_dlc}), u16(0x${(m.frames.e2e_id[rtof] or {
						0
					}).hex()}), ${m.frames.e2e_crc[rtof] or { 0 }}, ${m.frames.e2e_ctr[rtof] or { 0 }}, ${m.frames.secoc_fresh[rtof] or { 0 }}, 1, ${m.frames.secoc_mac[rtof] or { 0 }}, ${m.frames.secoc_maclen[rtof] or { 0 }})'
				} else {
					glue << '\t\tst.e2e_tx_${dk}.protect(&rf_${dk}.data[0], int(${r.to_dlc}), u16(0x${(m.frames.e2e_id[rtof] or {
						0
					}).hex()}), ${m.frames.e2e_crc[rtof] or { 0 }}, ${m.frames.e2e_ctr[rtof] or { 0 }})'
				}
			}
			if r_secoc {
				glue << '\t\tsecoc_save_${dk} := st.secoc_tx_${dk}'
				glue << '\t\tst.secoc_tx_${dk}.protect(&st.secoc_key_${dk}, &rf_${dk}.data[0], int(${r.to_dlc}), u16(0x${(m.frames.secoc_id[rtof] or {
					0
				}).hex()}), ${m.frames.secoc_fresh[rtof] or { 0 }}, ${m.frames.secoc_mac[rtof] or { 0 }}, ${m.frames.secoc_maclen[rtof] or {
					0
				}})'
			}
			mark_arg := if r_pre { 'rf_${dk}_pre' } else { 'rf_${dk}.data' }
			glue << '\t\tif ${dch}.send(rf_${dk}) {'
			glue << '\t\t\tst.rt_tx_${dk}.mark_sent(now, ${mark_arg}, ${r.to_dlc})'
			if r_pre {
				glue << '\t\t} else {'
				if r_e2e {
					glue << '\t\t\tst.e2e_tx_${dk} = e2e_save_${dk}'
				}
				if r_secoc {
					glue << '\t\t\tst.secoc_tx_${dk} = secoc_save_${dk}'
				}
				glue << '\t\t}'
			} else {
				glue << '\t\t}'
			}
			glue << '\t}'
		}
		glue << '}'
		glue << ''
		} // end: no tick handler for a module-host bus
		mut psig := 'ch can.Channel'
		for d in dests {
			psig += ', route_${snake(d)} can.Channel'
		}
		owns_trace := tctx.on() && bname == tctx.owner_bus
		if owns_trace {
			psig += trace_bridge_params()
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
			// this HOST bridge runs the tx pass once per 10 ms tick: a period below or
			// unaligned to that tick silently transmits at the wrong rate — reject it
			// loudly instead of letting should_send hide it (REQ-COM-003, codex #218)
			if (mode == 'cyclic' || mode == 'mixed') && (cyc < 10000 || cyc % 10000 != 0) {
				panic('frame "${msg}": cycle ${cyc / 1000} ms is not a multiple of the host ' +
					"bridge's 10 ms tick — the bridge cannot transmit at that period; use a " +
					'multiple of 10 ms')
			}
			glue << '\tst.tx_${msg}_st = com.TxState{'
			glue << '\t\tmode: com.TxMode.${mode}'
			glue << '\t\tcycle_us: ${cyc}'
			glue << '\t\tmin_delay_us: ${m.frames.tx_min_us[msg] or { 0 }}'
			glue << '\t}'
			if m.frames.secoc_here(msg, bname) {
				glue << '\tst.secoc_key_${msg} = secoc.new_key(${byte16_lit(m.frames.secoc_key[msg] or {
					[]u8{}
				})})'
			}
		}
		// one TxState per routed destination frame: its TX mode + cadence come from an
		// authored [[frame]].tx if present, else cyclic at the dest DBC GenMsgCycleTime
		// (default 100 ms). The destination composes + re-emits per this state.
		for r in dst_frames {
			dk := '${snake(r.to_bus)}_${snake(r.to_frame)}'
			tof := snake(r.to_frame)
			mode := m.frames.tx_mode[tof] or { 'cyclic' }
			// an authored [[frame]].tx with no cycle_ms inserts 0; treat 0 as absent and
			// fall back to the DBC cadence (else 100 ms) so should_send never sees 0.
			authored_us := m.frames.tx_cycle_us[tof] or { 0 }
			cyc := if authored_us > 0 {
				authored_us
			} else if r.to_cyc > 0 {
				r.to_cyc * 1000
			} else {
				100000
			}
			// routed dests run from the SAME 10 ms host scheduler (codex #218 r2)
			if (mode == 'cyclic' || mode == 'mixed') && (cyc < 10000 || cyc % 10000 != 0) {
				panic('routed dest frame "${tof}": cycle ${cyc / 1000} ms is not a multiple of ' +
					"the host bridge's 10 ms tick — use a multiple of 10 ms")
			}
			glue << '\tst.rt_tx_${dk} = com.TxState{'
			glue << '\t\tmode: com.TxMode.${mode}'
			glue << '\t\tcycle_us: ${cyc}'
			glue << '\t\tmin_delay_us: ${m.frames.tx_min_us[tof] or { 0 }}'
			glue << '\t}'
			if m.frames.secoc_here(tof, r.to_bus) {
				glue << '\tst.secoc_key_${dk} = secoc.new_key(${byte16_lit(m.frames.secoc_key[tof] or {
					[]u8{}
				})})'
			}
		}
		for msg, _ in rx_by_msg {
			if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
				glue << '\tst.rx_${msg}_st = com.RxState{'
				glue << '\t\ttimeout_us: ${m.frames.rx_timeout_us[msg]}'
				glue << '\t}'
				// armed from bridge start, not from a first frame: a sender absent since boot
				// still reaches `timeout` (docs/diagnostics.md §7, R3)
				glue << '\tst.rx_${msg}_st.arm(osal.now_us())'
			}
			if e2e_timeout(m, msg, bname) > 0 {
				glue << '\tst.e2e_rx_${msg}.timeout_us = ${e2e_timeout(m, msg, bname)}'
				glue << '\tst.e2e_rx_${msg}.arm(osal.now_us()) // from start, like the COM deadline'
			}
			if m.frames.secoc_here(msg, bname) {
				glue << '\tst.secoc_key_${msg} = secoc.new_key(${byte16_lit(m.frames.secoc_key[msg] or {
					[]u8{}
				})})'
			}
		}
		// SecOC key for a protected source-route frame (verified before decode). rx_routes,
		// NOT sig_routes: verify state+key live at the SOURCE (rx) side. With sig_routes a
		// crossing left the source key uninitialized AND made the destination assign a
		// source-key field its struct never declares — code that does not build (codex #200).
		mut src_key_seen := map[string]bool{}
		for r in rx_routes {
			frof := snake(r.from_frame)
			if frof in src_key_seen || frof in rx_by_msg {
				continue
			}
			if m.frames.secoc_here(frof, r.from_bus) {
				src_key_seen[frof] = true
				glue << '\tst.secoc_key_${frof} = secoc.new_key(${byte16_lit(m.frames.secoc_key[frof] or {
					[]u8{}
				})})'
			}
		}
		for c in conns {
			tp := snake(c.name)
			srv := 'st.conn_${tp}.server'
			glue << conn_init_lines(m, c, 'st.conn_${tp}')
			if m.dids.any(it.signal != '') {
				glue << '\tst.conn_${tp}.refresh = diag_refresh_${tp}'
			}
			glue << '\t${srv}.serves_reset = true // housekeep performs reset_req once answered'
			glue << '\t${srv}.serves_comm_control = true // and this bridge gates its frames on 0x28'
			if m.buses.len == 1 {
				glue << '\t${srv}.single_network = true // 0x28 "all networks" = this one'
			}
			// the host bridge injects the reference key (blobly_net's), seeded from the clock
			glue << security_init_lines(m, c, srv, 'st.sa_${tp}.ops(u32(osal.now_us()))')
			if m.faults.len > 0 {
				for i, f in m.faults {
					glue << '\tst.fmem.slots[${i}].dtc = u32(0x${f.dtc.hex()}) // ${f.name}'
					glue << '\tst.fmem.slots[${i}].confirm = u8(${f.confirm})'
					if f.signal != '' {
						glue << '\tst.fmem.slots[${i}].local = true // stepped and consumed on this thread'
					}
					if f.aging > 0 {
						glue << '\tst.fmem.slots[${i}].aging = u8(${f.aging})'
					}
				}
				for i, f in m.faults {
					if f.signal == '' {
						continue
					}
					glue << '\tst.sdeb_${i} = fault.Debounce{'
					if f.time_based {
						glue << '\t\ttime_based: true'
					}
					glue << '\t\tfail_thr: ${f.fail_thr}'
					glue << '\t\tpass_thr: ${f.pass_thr}'
					glue << debounce_step_lines(f, '\t\t')
					glue << '\t}'
				}
				glue << '\tst.fmem.n = ${m.faults.len}'
				glue << '\tst.fmem.init()'
				glue << '\t${srv}.faults = st.fmem.uds_ops() // 0x19 / 0x14 / 0x85'
			}
		}
		// module_host (above): no signal work, so no tick and no handler — it only has to DRAIN
		// its channel, since an unread rx queue backs up on a real driver. The frames go nowhere
		// until the trace module for this shape is generated again (#191).
		// The scheduler stays even with nothing to schedule: gen.v reserves a CpuLoad scratch
		// slot for EVERY bus, and partition_telem sums them, so a partition that skipped
		// accounting would report 0% forever while draining a busy diagnostic bus — under-
		// reporting the core it runs on. What a module-host bus does NOT get is a 10 ms tick
		// and an empty handler: that was only an unused-variable warning on every build.
		glue << '\tmut sched := loom.Scheduler{}'
		if !module_host {
			glue << '\tsched.every(10_000, io_${bb}_10ms, &st)'
		}
		if owns_trace {
			glue << trace_bridge_preamble(m, tctx)
		}
		glue << '\tfor {'
		if !owns_trace {
			// run_profiled takes the clock itself and stamps its own pass, so the traced owner
			// has no loom_t0 to open with — emitting one would be an unused variable.
			glue << '\t\tloom_t0 := osal.now_us()'
		}
		if module_host {
			glue << '\t\tmut rx := can.Frame{}'
			glue << '\t\tfor st.chan.recv(mut rx) {'
			glue << '\t\t\t// no consumer yet: the trace module that serves this bus is not'
			glue << '\t\t\t// generated for this shape (#191). Draining keeps the queue clear —'
			glue << '\t\t\t// an unread rx queue backs up on a real driver.'
			glue << '\t\t}'
		} else if owns_trace {
			// PROFILED: run_profiled calls the trace hook once per dispatch — that is where the
			// bridge's lane comes from (thread_hook -> note_thread) — and accounts the pass
			// itself, so no sched.account() follows (a second one charged every pass twice,
			// emb#270 r2).
			glue << trace_profiled_dispatch(true)
		} else {
			glue << '\t\tsched.run(loom_t0)'
		}
		if !owns_trace {
			glue << '\t\tloom_t1 := osal.now_us()'
			glue << '\t\tsched.account(loom_t1 - loom_t0, loom_t1) // per-core load'
		}
		if owns_trace {
			glue << trace_bridge_loop_body(m, tctx)
		}
		for p in producers {
			glue << p.partition_loop_body('b:${bname}')
		}
		glue << '\t\tosal.sleep_us(1000)'
		glue << '\t}'
		glue << '}'
	}
	return glue, bus_names, bus_dests
}

// eth_iocb_idx assigns each eth-frame signal its byte-IOC channel index —
// deterministic (sorted names), derived identically by the FB glue and the
// eth thread so the two sides can never disagree. Empty off the ThreadX
// target (the host bridge rides osal channels instead).
fn eth_iocb_idx(m Model) map[string]int {
	mut idx := map[string]int{}
	if !(m.target.threadx && m.eth_frames.len > 0) {
		return idx
	}
	mut names := []string{}
	for fr in m.eth_frames {
		for s in fr.signals {
			if s !in names {
				names << s
			}
		}
	}
	names.sort()
	for i, n in names {
		idx[n] = i
	}
	return idx
}

// emit_eth_target_create emits the eth comm thread's tx_thread_create line
// (both tx_application_define shapes call it; prio is the caller's platform
// slot — comm-thread class).
fn emit_eth_target_create(m Model, prio int) []string {
	mut glue := []string{}
	if !eth_thread_on(m) {
		return glue
	}
	if prio < 0 {
		panic('loom2v: the eth comm thread priority fell below 0 — it sits above the io ' +
			'thread (min FB - 2 without a CAN comm thread), so use FB priorities >= 2')
	}
	glue << "\tC._tx_thread_create(&g_eth_tcb[0], c'eth', eth_thread_entry, u32(0),"
	glue << '\t\t&g_eth_stack[0], u32(g_eth_stack.len), u32(${prio}), u32(${prio}), u32(0), u32(1))'
	return glue
}

// emit_eth_thread_target emits the ThreadX eth comm thread — the target twin
// of emit_eth_bridge, same chain over different seams: signals cross threads
// through the byte IOC pool (iocb_*, ioc.h size-proportional arenas) instead
// of osal channels, datagrams ride the NetX blob_eth_* seam instead of the
// POSIX Socket, time is board_now_us, pacing is one kernel tick. The two
// emitters share the codec (pack/unpack/consts) and the manifest — only the
// loop's seams differ, and each side is bench-proven against the same host
// oracle, so parameterizing one emitter over both seam sets would trade two
// straight-line loops for one harder-to-review indirection (deliberate).
fn emit_eth_thread_target(m Model, doc toml.Doc) []string {
	mut glue := []string{}
	if !eth_thread_on(m) {
		return glue
	}
	iocb := eth_iocb_idx(m)
	iface := m.eth_iface
	mut tx_frames := []EthFrame{}
	mut rx_frames := []EthFrame{}
	for fr in m.eth_frames {
		if fr.tx {
			tx_frames << fr
		} else {
			rx_frames << fr
		}
	}
	glue << ''
	glue << '// --- eth comm thread (${m.eth}): SOME/IP over the NetX seam (docs/someip.md'
	glue << '//     target rung). Rx/tx chain identical to the host bridge; IOC + NetX seams. ---'
	glue << 'fn eth_thread_entry(input u32) {'
	glue << "\tif C.blob_eth_open(c'${iface}', someip_port) != 0 {"
	glue << '\t\tfor {'
	glue << '\t\t\tC._tx_thread_sleep(1000) // dead endpoint — park, never fake a service'
	glue << '\t\t}'
	glue << '\t}'
	glue << shell_eth_init(m)
	if shell_on_eth(m) {
		glue << '\tmut rpc_buf := [1040]u8{} // someip.header_len + someip.max_rpc: ONE response datagram'
	}
	for fr in tx_frames {
		fb := snake(fr.name)
		glue << '\tmut tx_${fb}_st := com.TxState{'
		glue << '\t\tmode: com.TxMode.${fr.tx_mode}'
		glue << '\t\tcycle_us: ${fr.tx_cycle_us}'
		glue << '\t\tmin_delay_us: ${fr.tx_min_us}'
		glue << '\t}'
		if fr.e2e_on {
			glue << '\tmut e2e_tx_${fb} := e2e.TxState{}'
		}
	}
	for fr in rx_frames {
		glue << eth_rx_e2e_init(fr, 'C.board_now_us()')
	}
	glue << '\tpeer_ip := someip_peer_ip // local copy: a stable address for the send seam'
	if tx_frames.len > 0 {
		glue << '\tmut dgram := [80]u8{} // someip.header_len + com.max_pdu'
	}
	// rx buffers exist for EVERY image: a tx-only endpoint still drains its
	// bound socket — NetX queues unsolicited datagrams out of the same fixed
	// packet pool the sends allocate from, so an undrained queue starves tx
	// (the hand-wired glue's pool-starvation guard, kept by the generator)
	glue << '\tmut rx_buf := [80]u8{} // oversize datagrams truncate here and drop (real length reported)'
	glue << '\tmut rx_ip := [4]u8{}'
	glue << '\tmut rx_port := u16(0)'
	glue << '\tfor {'
	glue << '\t\tC._tx_thread_sleep(1) // one kernel tick — the [target] tick_ms pace'
	glue << '\t\tnow := C.board_now_us()'
	if rx_frames.len == 0 && !shell_on_eth(m) {
		glue << '\t\t// tx-only endpoint: drain and count unsolicited datagrams (bounded) —'
		glue << '\t\t// nothing routes here, but the pool packets must come back'
		glue << '\t\tfor _ in 0 .. 16 {'
		glue << '\t\t\tif C.blob_eth_recv(0, &rx_ip[0], &rx_port, &rx_buf[0], 80) < 0 {'
		glue << '\t\t\t\tbreak'
		glue << '\t\t\t}'
		glue << '\t\t\tg_eth_rx_drops++'
		glue << '\t\t}'
	}
	if rx_frames.len > 0 || shell_on_eth(m) {
		glue << '\t\t// bounded drain, coalesced publish — the host bridge rules (docs/someip.md)'
		for fr in rx_frames {
			fb := snake(fr.name)
			glue << '\t\tmut got_${fb} := false'
			glue << '\t\tmut rxok_${fb} := false // a value received, not a status published'
			for s in fr.signals {
				glue << '\t\tmut rxs_${snake(s)} := sig.${s}{}'
			}
		}
		glue << '\t\tfor _ in 0 .. 16 {'
		glue << '\t\t\trx_n := C.blob_eth_recv(0, &rx_ip[0], &rx_port, &rx_buf[0], 80)'
		glue << '\t\t\tif rx_n < 0 {'
		glue << '\t\t\t\tbreak // nothing pending — a zero-length datagram is REAL and falls through'
		glue << '\t\t\t}'
		glue << '\t\t\tif rx_n > 80 {'
		glue << '\t\t\t\tg_eth_rx_drops++ // truncated oversize: never decode a prefix'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		glue << '\t\t\t// static-peer source filter (REQ-NET-017)'
		glue << '\t\t\tif rx_ip[0] != someip_peer_ip[0] || rx_ip[1] != someip_peer_ip[1] || rx_ip[2] != someip_peer_ip[2] || rx_ip[3] != someip_peer_ip[3] || rx_port != someip_peer_port {'
		glue << '\t\t\t\tg_eth_rx_drops++'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		glue << '\t\t\trh, rh_ok := someip.decode(&rx_buf[0], rx_n)'
		glue << '\t\t\tif !rh_ok {'
		glue << '\t\t\t\tg_eth_rx_drops++'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		glue << emit_eth_rpc_branch(m)
		glue << '\t\t\tif someip.check_event(rh, rx_n, someip_service, someip_version) != .none {'
		glue << '\t\t\t\tg_eth_rx_drops++'
		glue << '\t\t\t\tcontinue'
		glue << '\t\t\t}'
		if rx_frames.len == 0 {
			// rpc-only image: a valid event NOTIFICATION has nowhere to route
			glue << '\t\t\tg_eth_rx_drops++ // no rx event frames configured'
		}
		for i, fr in rx_frames {
			fb := snake(fr.name)
			kw := if i == 0 { 'if' } else { '} else if' }
			glue << '\t\t\t${kw} rh.method == ${fb}_event_id {'
			glue << '\t\t\t\tif rx_n - someip.header_len != int(${fb}_len) {'
			glue << '\t\t\t\t\tg_eth_rx_drops++ // the router: the payload IS the frame, exactly'
			glue << '\t\t\t\t\tcontinue'
			glue << '\t\t\t\t}'
			glue << '\t\t\t\tmut pay_rx_${fb} := [64]u8{} // com.max_pdu'
			glue << '\t\t\t\tfor i in 0 .. int(${fb}_len) {'
			glue << '\t\t\t\t\tpay_rx_${fb}[i] = rx_buf[someip.header_len + i]'
			glue << '\t\t\t\t}'
			glue << eth_rx_accept(m, fr, '\t\t\t\t', 'g_eth_rx_drops++', 'rxok_${fb}')
		}
		if rx_frames.len > 0 {
			glue << '\t\t\t} else {'
			glue << '\t\t\t\tg_eth_rx_drops++ // an event id the config does not route'
			glue << '\t\t\t}'
		}
		glue << '\t\t}'
		for fr in rx_frames {
			glue << eth_rx_expiry(m, fr, '\t\t')
		}
		for fr in rx_frames {
			fb := snake(fr.name)
			glue << '\t\tif got_${fb} {'
			for s in fr.signals {
				glue << '\t\t\tC.iocb_pub(${iocb[s] or { 0 }}, &rxs_${snake(s)})'
			}
			glue << '\t\t\tif rxok_${fb} {'
			glue << '\t\t\t\tg_eth_rx_ok++ // receptions only: an expiry or an integrity publish is not one'
			glue << '\t\t\t}'
			glue << '\t\t}'
		}
	}
	for fr in tx_frames {
		fb := snake(fr.name)
		mut params := []string{}
		glue << '\t\tmut pay_${fb} := [64]u8{} // com.max_pdu'
		glue << '\t\tmut any_${fb} := false'
		for s in fr.signals {
			ss := snake(s)
			glue << '\t\tmut s_${ss} := sig.${s}{}'
		glue << '\t\tif C.iocb_get_ever(${iocb[s] or { 0 }}, &s_${ss}) != 0 {'
		glue << '\t\t\tany_${fb} = true'
		glue << '\t\t}'
			params << 's_${ss}'
		}
		glue << '\t\t${fb}_pack(mut pay_${fb}, ${params.join(', ')})'
		glue << '\t\tif any_${fb} && tx_${fb}_st.should_send(now, pay_${fb}, ${fb}_len) {'
		glue << '\t\t\tpre_${fb} := pay_${fb} // pre-E2E payload, for change detection'
		if fr.e2e_on {
			glue << '\t\t\te2e_save_${fb} := e2e_tx_${fb}'
			glue << '\t\t\te2e_tx_${fb}.protect(&pay_${fb}[0], int(${fb}_len), ${fb}_e2e_id, ${fb}_e2e_crc, ${fb}_e2e_ctr)'
		}
		glue << '\t\t\th_${fb} := someip.notification(someip_service, ${fb}_event_id, someip_version, int(${fb}_len))'
		glue << '\t\t\tn_${fb} := someip.encode(h_${fb}, &dgram[0])'
		glue << '\t\t\tfor i in 0 .. int(${fb}_len) {'
		glue << '\t\t\t\tdgram[n_${fb} + i] = pay_${fb}[i]'
		glue << '\t\t\t}'
		glue << '\t\t\tif C.blob_eth_send(0, &peer_ip[0], someip_peer_port, &dgram[0], n_${fb} + int(${fb}_len)) == 0 {'
		glue << '\t\t\t\ttx_${fb}_st.mark_sent(now, pre_${fb}, ${fb}_len)'
		if fr.e2e_on {
			glue << '\t\t\t} else {'
			glue << '\t\t\t\te2e_tx_${fb} = e2e_save_${fb} // unsent: keep the counter honest'
		}
		glue << '\t\t\t}'
		glue << '\t\t}'
	}
	glue << '\t}'
	glue << '}'
	return glue
}

// eth_only_img: the node's ONLY bus is the eth bus — no CAN channel exists
// anywhere in the image, so the app entry and run() are emitted channel-free
// (the io-only shape's rule, docs/someip.md target rung).
fn eth_only_img(m Model) bool {
	return m.eth != '' && m.buses.len == 1
}

// emit_eth_rpc_branch: the request path inside the eth thread's drain
// (docs/someip.md P3): a REQUEST message type takes this branch — envelope
// gate (check_request: live Request ID, bit-15-clear method), the router's
// method match (unknown method ANSWERS rc_unknown_method — a served port is
// never a silent drop), the REQ-NET-018 access gate (rc_denied before the
// command runs), then dispatch -> ONE response datagram (correlation
// mirrored by someip.response). Single in-flight per method by construction:
// dispatch is synchronous on this thread.
fn emit_eth_rpc_branch(m Model) []string {
	mut glue := []string{}
	if !shell_on_eth(m) {
		return glue
	}
	am := if m.shell.allow_mutate { 'true' } else { 'false' }
	glue << '\t\t\tif rh.mtype == someip.mt_request {'
	glue << '\t\t\t\tif someip.check_request(rh, rx_n, someip_service, someip_version) != .none {'
	glue << '\t\t\t\t\tg_eth_rx_drops++'
	glue << '\t\t\t\t\tcontinue'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tif rh.method != u16(0x${m.shell.method.hex()}) {'
	glue << '\t\t\t\t\teh := someip.error_response(rh, someip.rc_unknown_method)'
	glue << '\t\t\t\t\ten := someip.encode(eh, &rpc_buf[0])'
	glue << '\t\t\t\t\tC.blob_eth_send(0, &peer_ip[0], someip_peer_port, &rpc_buf[0], en)'
	glue << '\t\t\t\t\tcontinue'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\t// the payload IS the command line (requests stay <= max_payload)'
	glue << '\t\t\t\tmut cmd_line := [64]u8{}'
	glue << '\t\t\t\tcl := rx_n - someip.header_len'
	glue << '\t\t\t\tfor i in 0 .. cl {'
	glue << '\t\t\t\t\tcmd_line[i] = rx_buf[someip.header_len + i]'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tg_sh.rsp.len = 0 // module-sized Rsp lives IN the module __global, never on the 4 KB comm stack (codex #206)'
	glue << '\t\t\t\tif !g_sh.dispatch(cmd_line, cl, now, ${am}, mut g_sh.rsp) {'
	glue << '\t\t\t\t\t// the access gate refused a state-changing command (REQ-NET-018)'
	glue << '\t\t\t\t\teh := someip.error_response(rh, someip.rc_denied)'
	glue << '\t\t\t\t\ten := someip.encode(eh, &rpc_buf[0])'
	glue << '\t\t\t\t\tC.blob_eth_send(0, &peer_ip[0], someip_peer_port, &rpc_buf[0], en)'
	glue << '\t\t\t\t\tcontinue'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tmut rl := int(g_sh.rsp.len)'
	glue << '\t\t\t\tif rl > shell.max_rsp {'
	glue << '\t\t\t\t\trl = shell.max_rsp // the Rsp BUFFER bound: an over-reporting C command must not read past it'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tif rl > someip.max_rpc {'
	glue << '\t\t\t\t\trl = someip.max_rpc // one datagram, never segmentation'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tph := someip.response(rh, rl)'
	glue << '\t\t\t\tpn := someip.encode(ph, &rpc_buf[0])'
	glue << '\t\t\t\tfor i in 0 .. rl {'
	glue << '\t\t\t\t\trpc_buf[pn + i] = g_sh.rsp.buf[i]'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tC.blob_eth_send(0, &peer_ip[0], someip_peer_port, &rpc_buf[0], pn + rl)'
	glue << '\t\t\t\tcontinue'
	glue << '\t\t\t}'
	return glue
}

// did_refresh_fn emits connection `tp`'s live-signal DID refresh — the fn comm/diag calls before
// every dispatch, physical or functional, so a read answers with the value current then. None when
// no DID is signal-backed.
fn did_refresh_fn(m Model, tp string) []string {
	if !m.dids.any(it.signal != '') {
		return []string{}
	}
	mut out := ['', 'fn diag_refresh_${tp}(mut srv uds.Server) {']
	for idx, did in m.dids {
		if did.signal == '' {
			continue
		}
		si := m.sig_of[did.signal] or { continue }
		f := snake(did.signal)
		out << '\tmut ${f}_did := sig.${did.signal}{}'
		out << '\tif osal.${acquire_fn(si.transport)}(${f}_ch, &${f}_did, u8(sizeof(${f}_did))) {'
		out << did_encode_lines(idx, '${f}_did.${si.val_field}', si.val_type, '\t\t')
		out << '\t}'
	}
	out << '}'
	return out
}

// security_levels: the 0x27 levels a server must serve — every level some [[did]] read or write gate
// names (bit L-1 for level L). A level nothing is gated on is not offered: unlocking it opens nothing.
fn security_levels(dids []DidCfg) u8 {
	mut mask := u8(0)
	for d in dids {
		for l in [d.read_security, d.write_security] {
			if l != 0 {
				mask |= u8(1) << (l - 1)
			}
		}
	}
	return mask
}

// rx_status_fields: the bridge-owned fields of a received signal's publish — `status` and, on an
// E2E-protected frame, `lost` (the frames the sequence showed missing, wrapping) — or '' for a
// signal that declares neither.
fn rx_status_fields(si SigInfo, status string, lost string) string {
	mut f := ''
	if si.has_status {
		f += ', status: ${status}'
	}
	if si.lost_type != '' && lost != '' {
		f += ', lost: ${si.lost_type}(${lost})'
	}
	return f
}

// rx_integrity: the publish of a frame that failed its protection check — status `integrity`
// (value zero: nothing in the frame can be trusted) to each of its signals that carries a status —
// and a re-arm of the frame's deadline, which then runs from this frame: `integrity` holds until a
// good frame, or until the deadline passes with none (`timeout` — silence is the newer fact).
// Behind the 0x28 gate like any other publish.
// `rearm_e2e`: apply the E2E receive rule here — true for a SecOC failure, which never reaches the
// E2E check; an E2E CRC failure has already been through RxState.receive_ex.
fn rx_integrity(m Model, list []string, msg string, lost string, gate string, ind string, rearm_e2e bool) []string {
	mut out := []string{}
	if (m.frames.rx_timeout_us[msg] or { 0 }) > 0 {
		out << '${ind}st.rx_${msg}_st.arm(now)' // every deadline, status or not
	}
	// The E2E timeout counts VALID messages only, so a corrupt frame does not refresh it — a
	// corrupt-only sender runs it out from the last valid one. But once it HAS fired, this
	// integrity is the newer fact, and silence after it must reach `timeout` again: re-arm then.
	if rearm_e2e && e2e_timeout(m, msg, m.frames.frame_bus[msg] or { '' }) > 0 {
		// the same rule as an E2E CRC failure, from the same function (a corrupt frame is a corrupt
		// frame, whichever check caught it)
		out << '${ind}_ = st.e2e_rx_${msg}.receive(now, .crc_error)'
	}
	mut i := ind
	if gate != '' && list.any((m.sig_of[it] or { SigInfo{} }).has_status) {
		out << '${i}if ${gate} {'
		i += '\t'
	}
	for sname in list {
		si := m.sig_of[sname] or { continue }
		if !si.has_status {
			continue
		}
		fld := snake(sname)
		out << '${i}mut ${fld} := sig.${sname}{ ${rx_status_fields(si, '.integrity', lost)[2..]} }'
		out << '${i}osal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
	}
	out << rx_group_hooks(m, list.filter((m.sig_of[it] or { SigInfo{} }).has_status), i)
	if i != ind {
		out << '${ind}}'
	}
	return out
}

// lost_expr: the E2E lost-frame count a received signal publishes — '' when the frame has no E2E
// or none of its signals declares `lost`. Where a diagnostic server can switch reception off
// (0x28), the frames missed meanwhile are subtracted (e2e_hidden): commanded silence is not loss.
fn lost_expr(m Model, msg string, bname string, has_diag bool) string {
	if !m.frames.e2e_here(msg, bname) {
		return ''
	}
	if !m.sig_names.any((m.sig_of[it] or { SigInfo{} }).lost_type != ''
		&& (m.sig_of[it] or { SigInfo{} }).dbc_msg == msg) {
		return ''
	}
	if has_diag {
		return 'st.e2e_rx_${msg}.lost_frames - st.e2e_hidden_${msg}'
	}
	return 'st.e2e_rx_${msg}.lost_frames'
}

// rx_gate_sample: every sampling of the 0x28 receive gate — at the top of a pass, after a
// functional request served inside the drain, after the pass's requests — in ONE place, with the
// rule that rides on it: whenever reception is found off, the silence is LATCHED — for the rx
// deadlines (restarted when reception returns) and for each E2E frame whose loss count hides
// commanded silence. So a disable and re-enable inside one drain (two suppressed functional
// requests) is remembered like one that spans passes.
fn rx_gate_sample(m Model, conns []IsotpConn, rx_msgs []string, bname string, ind string, decl bool) []string {
	mut out := []string{}
	lhs := if decl { 'mut diag_rx_ok :=' } else { 'diag_rx_ok =' }
	out << '${ind}${lhs} ${conns.map('st.conn_${snake(it.name)}.server.rx_enabled()').join(' && ')}'
	quiet := rx_msgs.filter(lost_expr(m, it, bname, true).contains('e2e_hidden'))
	deadlines := rx_off_latched(m, rx_msgs, bname)
	if quiet.len > 0 || deadlines {
		out << '${ind}if !diag_rx_ok { // silence commanded: latch it, frame or not'
		if deadlines {
			out << '${ind}\tst.diag_rx_was_off = true'
		}
		for msg in quiet {
			out << '${ind}\tst.e2e_quiet_${msg} = true'
		}
		// a watched signal's status goes stale the moment reception stops: not known again until a
		// frame (or a restarted deadline) publishes it — reset HERE, never after the drain, so a
		// publication after the re-enable is not overwritten
		if m.isotp_conns.len > 0 && bname == m.isotp_conns[0].bus {
			for src in fault_sources(m) {
				out << '${ind}\tst.fsrc_${snake(src)} = .never_received'
			}
		}
		out << '${ind}}'
	}
	return out
}

// e2e_timeout: the E2E-owned reception timeout of an rx frame on this bus, in µs (0 = none).
fn e2e_timeout(m Model, msg string, bname string) int {
	if !m.frames.e2e_here(msg, bname) {
		return 0
	}
	return m.frames.e2e_timeout_us[msg] or { 0 }
}

// has_deadline: the frame is monitored for silence — by the COM deadline, the E2E one, or both.
fn has_deadline(m Model, msg string, bname string) bool {
	return (m.frames.rx_timeout_us[msg] or { 0 }) > 0 || e2e_timeout(m, msg, bname) > 0
}

// fault_pass_lines: the fault memory's share of the bridge pass, at its TOP — before the rx drain,
// where functional requests are served inline, and before the physical dispatch — so every 0x19
// reads the newest consumed state: the signal-status faults' levels are stepped, each fault-owning
// FB's report cell is consumed slot by slot and the clear generations go back in its control cell.
// (Events and the operation cycle are handled where the frame is decoded, in bus order.)
fn fault_pass_lines(m Model) []string {
	if m.faults.len == 0 {
		return []string{}
	}
	mut out := []string{}
	out << signal_fault_step_lines(m, '\t')
	for fb in fault_fbs(m) {
		f := snake(fb)
		out << '\tosal.${acquire_fn('triple')}(fault_rep_${f}_ch, &st.frep_${f}, u8(sizeof(st.frep_${f})))'
		mut k := 0
		for i, fc in m.faults {
			if fc.fb != fb {
				continue
			}
			out << '\tst.fmem.consume(${i}, st.frep_${f}.r[${k}])'
			out << '\tst.fctl_${f}.gen[${k}] = st.fmem.control_gen(${i})'
			k++
		}
		out << '\tosal.${publish_fn('triple')}(fault_ctl_${f}_ch, &st.fctl_${f}, u8(sizeof(st.fctl_${f})))'
	}
	return out
}

// rx_publish_hooks: what a signal-status fault needs from EVERY publication of a signal it
// watches — a good decode, a deadline or E2E timeout, an integrity failure, a late frame — in one
// place, so no publish path can be missed. Each publication IS a test result (failed, passed, or
// not tested), stepped and consumed right here, so it lands on the correct side of every boundary
// inside the drain: a cycle edge, a clear, a 0x28 switching reception. The pass top only steps
// the level for a pass with no publication (a timeout holding, a sender gone quiet).
// Called from rx_group_hooks, which also moves the operation cycle.
fn rx_publish_hooks(m Model, sname string, fld string, ind string) []string {
	if sname !in fault_sources(m) {
		return []string{}
	}
	mut out := []string{}
	out << '${ind}st.fsrc_${snake(sname)} = ${fld}.status'
	for i, f in m.faults {
		if f.signal != sname {
			continue
		}
		res := match f.on {
			'timeout', 'integrity' {
				'if ${fld}.status == .${f.on} { fault.TestResult.failed } else if ${fld}.status == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
			else {
				// the count wraps in its own type: a gap is a small forward step, modulo
				lt := (m.sig_of[f.signal] or { SigInfo{} }).lost_type
				half := match lt {
					'u8' { '0x80' }
					'u16' { '0x8000' }
					else { '0x8000_0000' }
				}
				d := '${lt}(${fld}.lost - st.slost_${i})'
				'if ${d} != 0 && ${d} < ${half} { fault.TestResult.failed } else if ${fld}.status == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
		}
		out << '${ind}st.sdeb_${i}.apply(st.fmem.control_gen(${i}))'
		out << '${ind}st.sdeb_${i}.step(${res}, now, diag_rx_ok)'
		out << '${ind}st.fmem.consume(${i}, st.sdeb_${i}.rep)'
		out << '${ind}st.sev_${i} = true'
		if f.on == 'lost' {
			out << '${ind}st.slost_${i} = ${fld}.lost'
		}
	}
	return out
}

// rx_group_hooks: the fault memory's share of one publication group (the signals one frame, one
// deadline or one integrity failure publishes together), after all of them are published. The
// operation cycle moves where its signal is published, in bus order (an off/on pair in one drain
// is two edges): a RISING edge before the group's results and a FALLING one after them, so a
// frame that starts or ends the cycle and also carries a result (a gap, its own timeout) records
// that result inside the cycle either way.
fn rx_group_hooks(m Model, list []string, ind string) []string {
	mut out := []string{}
	if m.faults.len == 0 {
		return out
	}
	cyc := m.fault_cycle.all_before('.')
	cf := m.fault_cycle.all_after('.')
	has_cycle := m.fault_cycle != '' && cyc in list
	if has_cycle {
		out << '${ind}if ${snake(cyc)}.${cf} && !st.fcycle_on {'
		out << '${ind}\tst.fmem.cycle_start()'
		out << '${ind}\tst.fcycle_on = true'
		out << '${ind}}'
	}
	for sname in list {
		out << rx_publish_hooks(m, sname, snake(sname), ind)
	}
	if has_cycle {
		out << '${ind}if !${snake(cyc)}.${cf} && st.fcycle_on {'
		out << '${ind}\tst.fmem.cycle_end()'
		out << '${ind}\tst.fcycle_on = false'
		out << '${ind}}'
	}
	return out
}

// signal_fault_step_lines: the pass-top step of each signal-status fault — its watched signal's
// LEVEL (the condition still holding, a good status, or not known) — for a pass whose drain
// published nothing (rx_publish_hooks stepped those). While the test is disabled it always steps,
// disabled, so a time-based run never survives a 0x28 pause.
fn signal_fault_step_lines(m Model, ind string) []string {
	mut out := []string{}
	for i, f in m.faults {
		if f.signal == '' {
			continue
		}
		src := 'st.fsrc_${snake(f.signal)}'
		// lost is an event only: its level can pass, never fail
		res := match f.on {
			'timeout', 'integrity' {
				'if ${src} == .${f.on} { fault.TestResult.failed } else if ${src} == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
			else {
				'if ${src} == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }'
			}
		}
		// while 0x28 has reception off (or its silence is still latched) nothing is received: the
		// level is not known, so the test is disabled, not passed or failed
		en := if rx_off_latched(m, []string{}, m.isotp_conns[0].bus) { 'diag_rx_ok && !st.diag_rx_was_off' } else { 'diag_rx_ok' }
		out << '${ind}if st.sev_${i} && ${en} {'
		out << '${ind}\tst.sev_${i} = false'
		out << '${ind}} else {'
		out << '${ind}\tst.sev_${i} = false'
		out << '${ind}\tst.sdeb_${i}.apply(st.fmem.control_gen(${i}))'
		out << '${ind}\tst.sdeb_${i}.step(${res}, now, ${en})'
		out << '${ind}\tst.fmem.consume(${i}, st.sdeb_${i}.rep)'
		out << '${ind}}'
	}
	return out
}

// rx_off_latched: the diagnostic bridge keeps the 0x28 silence latch (diag_rx_was_off) — when a
// received frame has a deadline to restart, or a signal-status fault watches a status that goes
// stale during the pause. ONE predicate for the state field, the sampler and the restart block.
fn rx_off_latched(m Model, rx_msgs []string, bname string) bool {
	if m.isotp_conns.len > 0 && bname == m.isotp_conns[0].bus && m.faults.any(it.signal != '') {
		return true
	}
	if rx_msgs.any(has_deadline(m, it, bname)) {
		return true
	}
	bus := if m.isotp_conns.len > 0 { m.isotp_conns[0].bus } else { '' }
	if rx_msgs.len == 0 && bus == bname {
		for sname in m.sig_names {
			si := m.sig_of[sname] or { continue }
			if si.external && si.rx && si.bus == bus && has_deadline(m, si.dbc_msg, bus) {
				return true
			}
		}
	}
	return false
}

// --- the SOME/IP receive path's E2E and receive status (REQ-E2E-002, #299): one set of templates
// for the host bridge and the ThreadX eth thread, so the two cannot answer a frame differently,
// and the decision itself is comm/e2e's RxState.receive — the rule lives in one tested function,
// the templates only map its verdict to a publish. Signals without a `status` field get values
// only; on an E2E frame every signal has one (validate_e2e_timeouts).

// eth_rx_e2e_init declares a received frame's RxState and arms its timeout from start.
fn eth_rx_e2e_init(fr EthFrame, now string) []string {
	if !fr.e2e_on {
		return []
	}
	fb := snake(fr.name)
	return ['\tmut e2e_rx_${fb} := e2e.RxState{', '\t\ttimeout_us: ${fr.e2e_tmo_us}', '\t}',
		'\te2e_rx_${fb}.arm(${now}) // from start: a sender absent since then times out too']
}

// eth_status_set is `rxs_<sig> = sig.<Sig>{ status: <st> }` for every signal of the frame: the
// value withheld, as the CAN bridge withholds it.
fn eth_status_set(m Model, fr EthFrame, ind string, st string) []string {
	mut out := []string{}
	for sn in fr.signals {
		si := m.sig_of[sn] or { SigInfo{} }
		if si.has_status {
			out << '${ind}rxs_${snake(sn)} = sig.${sn}{ status: ${st}${eth_lost_field(fr, si)} }'
		}
	}
	return out
}

// eth_lost_field is `, lost: T(<count>)` for a signal with a lost counter: the E2E sequence's
// count of frames it showed missing (REQ-E2E-002's skipped-sequence report), as the CAN bridge
// carries it — a `lost` verdict is otherwise indistinguishable from `ok`.
fn eth_lost_field(fr EthFrame, si SigInfo) string {
	if si.lost_type == '' || !fr.e2e_on {
		return ''
	}
	return ', lost: ${si.lost_type}(e2e_rx_${snake(fr.name)}.lost_frames)'
}

// eth_rx_accept is a received frame's body once its payload is in pay_rx_<fb>: the E2E check, the
// verdict, the unpack and the status. `drop` counts a refusal; `ok_flag`, when given, is set on a
// frame whose value was published (the target counts those as receptions).
fn eth_rx_accept(m Model, fr EthFrame, ind string, drop string, ok_flag string) []string {
	fb := snake(fr.name)
	mut uargs := []string{}
	for sn in fr.signals {
		uargs << 'mut rxs_${snake(sn)}'
	}
	mut ok := ['${fb}_unpack(pay_rx_${fb}, ${uargs.join(', ')})']
	for sn in fr.signals {
		si := m.sig_of[sn] or { SigInfo{} }
		if si.has_status {
			ok << 'rxs_${snake(sn)}.status = .ok'
		}
		if eth_lost_field(fr, si) != '' {
			ok << 'rxs_${snake(sn)}.lost = ${si.lost_type}(e2e_rx_${fb}.lost_frames)'
		}
	}
	ok << 'got_${fb} = true'
	if ok_flag != '' {
		ok << '${ok_flag} = true'
	}
	mut out := []string{}
	if !fr.e2e_on {
		for l in ok {
			out << ind + l
		}
		return out
	}
	out << '${ind}e2e_${fb} := e2e_rx_${fb}.check(&pay_rx_${fb}[0], int(${fb}_len), ${fb}_e2e_id, ${fb}_e2e_crc, ${fb}_e2e_ctr)'
	out << '${ind}match e2e_rx_${fb}.receive(now, e2e_${fb}) {'
	out << '${ind}\t.ok {'
	for l in ok {
		out << ind + '\t\t' + l
	}
	out << '${ind}\t}'
	out << '${ind}\t.timeout {'
	out << eth_status_set(m, fr, ind + '\t\t', '.timeout')
	out << '${ind}\t\tgot_${fb} = true'
	out << '${ind}\t}'
	out << '${ind}\t.integrity {'
	out << '${ind}\t\t${drop}'
	out << eth_status_set(m, fr, ind + '\t\t', '.integrity')
	out << '${ind}\t\tgot_${fb} = true'
	out << '${ind}\t}'
	out << '${ind}\t.none {'
	out << '${ind}\t\t${drop} // a repeat: the last value stands'
	out << '${ind}\t}'
	out << '${ind}}'
	return out
}

// eth_rx_expiry publishes `timeout` once the E2E timeout runs out with nothing valid since.
fn eth_rx_expiry(m Model, fr EthFrame, ind string) []string {
	if !fr.e2e_on {
		return []
	}
	fb := snake(fr.name)
	mut out := ['${ind}if e2e_rx_${fb}.expired(now) {']
	out << eth_status_set(m, fr, ind + '\t', '.timeout')
	out << '${ind}\tgot_${fb} = true'
	out << '${ind}}'
	return out
}
