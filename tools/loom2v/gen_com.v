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
		if fr.e2e_on {
			glue << '\tmut e2e_rx_${snake(fr.name)} := e2e.RxState{}'
		}
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
			if fr.e2e_on {
				// the trailer check gates the unpack, as the CAN bridge gates
				// decode: ok and lost are usable (loss flagged, data valid),
				// a wrong CRC/id is a counted drop
				glue << '\t\t\t\tif !e2e_rx_${fb}.check(&pay_rx_${fb}[0], int(${fb}_len), ${fb}_e2e_id, ${fb}_e2e_crc, ${fb}_e2e_ctr).usable() {'
				glue << '\t\t\t\t\trx_drops++'
				glue << '\t\t\t\t\tcontinue'
				glue << '\t\t\t\t}'
			}
			mut uargs := []string{}
			for s in fr.signals {
				uargs << 'mut rxs_${snake(s)}'
			}
			glue << '\t\t\t\t${fb}_unpack(pay_rx_${fb}, ${uargs.join(', ')})'
			glue << '\t\t\t\tgot_${fb} = true'
		}
		glue << '\t\t\t} else {'
		glue << '\t\t\t\trx_drops++ // an event id the config does not route'
		glue << '\t\t\t}'
		glue << '\t\t}'
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

fn emit_bridges(m Model, comm_thread_on bool, producers []Producer) ([]string, []string, map[string][]string) {
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

		// SIGNAL routes on this bus, grouped by destination frame: the P2a.2b producer
		// stores each routed value on rx (decode -> physical, with a freshness stamp),
		// then composes the WHOLE destination frame and re-emits it per the dest frame's
		// cadence + TX mode (rate adaptation), from THIS (source) bridge which already
		// holds the destination channel. dst_frames = one representative Route per
		// distinct (to_bus, to_frame).
		mut sig_routes := []Route{}
		for r in my_routes {
			if r.signal != '' {
				sig_routes << r
			}
		}
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
			}
			if m.frames.secoc_here(msg, bname) {
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
		for r in sig_routes {
			frof := snake(r.from_frame)
			if frof in src_verify_seen || frof in rx_by_msg {
				continue
			}
			if m.frames.e2e_here(frof, r.from_bus) {
				src_verify_seen[frof] = true
				glue << '\te2e_rx_${frof} e2e.RxState'
			} else if m.frames.secoc_here(frof, r.from_bus) {
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
		glue << ''
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
					} else if s_e2e {
						glue << '\t\t\tif st.e2e_rx_${frof}.check(&rx.data[0], int(${r.from_dlc}), u16(0x${(m.frames.e2e_id[frof] or {
							0
						}).hex()}), ${m.frames.e2e_crc[frof] or { 0 }}, ${m.frames.e2e_ctr[frof] or { 0 }}).usable() {'
						ind = '\t\t\t\t'
					}
					glue << '${ind}st.${rk}_v = ${frof}_${snake(r.signal)}_phys(rx.data)'
					glue << '${ind}st.${rk}_fresh = now'
					if s_e2e || s_secoc {
						glue << '\t\t\t}'
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
				glue << '\t\tif rx.id == u32(0x${c.rx_id.hex()}) && !rx.ext {'
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
			e2e_here := m.frames.e2e_here(msg, bname)
			secoc_here := m.frames.secoc_here(msg, bname)
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
		// SIGNAL-route producers (P2a.2b): compose each destination frame from its
		// routed signals and re-emit per the frame's own cadence + TX mode (rate
		// adaptation), gated on the dest channel's tx_ready. A signal not yet received
		// (fresh == 0) or stale beyond its source deadline suppresses the frame, so a
		// downstream receiver detects the loss instead of seeing stale-as-fresh.
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
				authored_to := m.frames.rx_timeout_us[frof] or { 0 }
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
			dch := 'st.route_${snake(r.to_bus)}'
			glue << '\tif rf_${dk}_ok && ${dch}.tx_ready() && st.rt_tx_${dk}.should_send(now, rf_${dk}.data, ${r.to_dlc}) {'
			if r_pre {
				glue << '\t\trf_${dk}_pre := rf_${dk}.data // pre-protect payload, for mark_sent'
			}
			if r_e2e {
				glue << '\t\te2e_save_${dk} := st.e2e_tx_${dk}'
				glue << '\t\tst.e2e_tx_${dk}.protect(&rf_${dk}.data[0], int(${r.to_dlc}), u16(0x${(m.frames.e2e_id[rtof] or {
					0
				}).hex()}), ${m.frames.e2e_crc[rtof] or { 0 }}, ${m.frames.e2e_ctr[rtof] or { 0 }})'
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
			}
			if m.frames.secoc_here(msg, bname) {
				glue << '\tst.secoc_key_${msg} = secoc.new_key(${byte16_lit(m.frames.secoc_key[msg] or {
					[]u8{}
				})})'
			}
		}
		// SecOC key for a protected source-route frame (verified before decode).
		mut src_key_seen := map[string]bool{}
		for r in sig_routes {
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
			glue << '\tst.tp_${tp} = isotp.Link{'
			glue << '\t\tbs:    ${c.bs}'
			glue << '\t\tstmin: ${c.stmin}'
			glue << '\t}'
			// no field defaults on Link (the _vinit rule): the N_Bs/WFTmax
			// timeouts are set explicitly or a lost FC wedges the bridge
			glue << '\tst.tp_${tp}.init_defaults()'
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
	mut iface := ''
	if bv := doc.value_opt('bus') {
		if bc := bv.as_map()[m.eth] {
			iface = (bc.as_map()['interface'] or { toml.Any('') }).string()
		}
	}
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
		if fr.e2e_on {
			glue << '\tmut e2e_rx_${snake(fr.name)} := e2e.RxState{}'
		}
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
			if fr.e2e_on {
				glue << '\t\t\t\tif !e2e_rx_${fb}.check(&pay_rx_${fb}[0], int(${fb}_len), ${fb}_e2e_id, ${fb}_e2e_crc, ${fb}_e2e_ctr).usable() {'
				glue << '\t\t\t\t\tg_eth_rx_drops++'
				glue << '\t\t\t\t\tcontinue'
				glue << '\t\t\t\t}'
			}
			mut uargs := []string{}
			for s in fr.signals {
				uargs << 'mut rxs_${snake(s)}'
			}
			glue << '\t\t\t\t${fb}_unpack(pay_rx_${fb}, ${uargs.join(', ')})'
			glue << '\t\t\t\tgot_${fb} = true'
		}
		if rx_frames.len > 0 {
			glue << '\t\t\t} else {'
			glue << '\t\t\t\tg_eth_rx_drops++ // an event id the config does not route'
			glue << '\t\t\t}'
		}
		glue << '\t\t}'
		for fr in rx_frames {
			fb := snake(fr.name)
			glue << '\t\tif got_${fb} {'
			for s in fr.signals {
				glue << '\t\t\tC.iocb_pub(${iocb[s] or { 0 }}, &rxs_${snake(s)})'
			}
			glue << '\t\t\tg_eth_rx_ok++'
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
	glue << '\t\t\t\tmut rpc_rsp := shell.Rsp{}'
	glue << '\t\t\t\tif !g_sh.dispatch(cmd_line, cl, now, ${am}, mut rpc_rsp) {'
	glue << '\t\t\t\t\t// the access gate refused a state-changing command (REQ-NET-018)'
	glue << '\t\t\t\t\teh := someip.error_response(rh, someip.rc_denied)'
	glue << '\t\t\t\t\ten := someip.encode(eh, &rpc_buf[0])'
	glue << '\t\t\t\t\tC.blob_eth_send(0, &peer_ip[0], someip_peer_port, &rpc_buf[0], en)'
	glue << '\t\t\t\t\tcontinue'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tmut rl := int(rpc_rsp.len)'
	glue << '\t\t\t\tif rl > shell.max_rsp {'
	glue << '\t\t\t\t\trl = shell.max_rsp // the Rsp BUFFER bound: an over-reporting C command must not read past it'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tif rl > someip.max_rpc {'
	glue << '\t\t\t\t\trl = someip.max_rpc // one datagram, never segmentation'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tph := someip.response(rh, rl)'
	glue << '\t\t\t\tpn := someip.encode(ph, &rpc_buf[0])'
	glue << '\t\t\t\tfor i in 0 .. rl {'
	glue << '\t\t\t\t\trpc_buf[pn + i] = rpc_rsp.buf[i]'
	glue << '\t\t\t\t}'
	glue << '\t\t\t\tC.blob_eth_send(0, &peer_ip[0], someip_peer_port, &rpc_buf[0], pn + rl)'
	glue << '\t\t\t\tcontinue'
	glue << '\t\t\t}'
	return glue
}
