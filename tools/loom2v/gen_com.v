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
			continue // rx unpack arrives with the rx rung
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

// emit_eth_bridge emits the eth comm thread (docs/someip.md, UDP tx rung):
// acquire each tx frame's signals from IOC, pack the derived layout, gate on
// com.TxState (the same cyclic/event/mixed machinery as CAN), stamp the E2E
// trailer when configured, wrap in the comm/someip notification header, and
// send one datagram to the static peer through the driver/eth seam.
fn emit_eth_bridge(m Model) []string {
	mut glue := []string{}
	mut tx_frames := []EthFrame{}
	for fr in m.eth_frames {
		if fr.tx {
			tx_frames << fr
		}
	}
	if tx_frames.len == 0 {
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
	glue << '\tmut dgram := [80]u8{} // someip.header_len + com.max_pdu'
	glue << '\tfor {'
	glue << '\t\tnow := osal.now_us()'
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
				if r.signal != '' {
					// SIGNAL route: decode the routed signal from the source frame (its DBC
					// codec), re-encode it into the DESTINATION frame — a different id + layout
					// — and send on the destination bus. Both codec fns live in dbc_gen.v.
					// Require rx.len == source DLC so the decode never reads stale bytes.
					glue << '\t\tif rx.id == u32(0x${r.from_id.hex()}) && rx.len == ${r.from_dlc} {'
					glue << '\t\t\tmut fwd := can.Frame{'
					glue << '\t\t\t\tid:  u32(0x${r.to_id.hex()})'
					glue << '\t\t\t\tlen: ${r.to_dlc}'
					glue << '\t\t\t}'
					glue << '\t\t\t${snake(r.to_frame)}_${snake(r.signal)}_set_raw(mut fwd.data, ${snake(r.from_frame)}_${snake(r.signal)}_raw(rx.data))'
					// gate on the DESTINATION channel's tx_ready so a full Tx FIFO isn't
					// pushed into (a cyclic source re-forwards next tick). Retain + retry
					// per the dest frame's TX mode is the destination-producer step (next).
					glue << '\t\t\tif st.route_${snake(r.to_bus)}.tx_ready() {'
					glue << '\t\t\t\tst.route_${snake(r.to_bus)}.send(fwd)'
					glue << '\t\t\t}'
					glue << '\t\t}'
					continue
				}
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
