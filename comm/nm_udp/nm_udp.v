module nm_udp

import comm.nm

// nm_udp — UDP Network Management binding over comm/nm (docs/someip.md, docs/nm.md).
// Transmits and receives 8-byte UDP-NM datagrams over Ethernet sockets.
// PDU Layout: Byte 0: Source Node ID (NID), Byte 1: Control Bit Vector (CBV),
// Bytes 2..7: Partial Network (PN) request mask (48-bit little-endian).

pub struct UdpBinding {
pub mut:
	node_id  u8
	pn_local u64
	port     u16
}

// new_udp_binding initializes a UdpBinding without relying on struct field defaults
// (avoiding the target _vinit trap).
pub fn new_udp_binding(node_id u8, pn_local u64, port u16) UdpBinding {
	p := if port == 0 { u16(30490) } else { port }
	return UdpBinding{
		node_id:  node_id
		pn_local: pn_local
		port:     p
	}
}

// encode_udp serializes an outgoing UDP-NM 8-byte PDU payload.
pub fn (b UdpBinding) encode_udp(n &nm.Nm) [8]u8 {
	frame := n.build_frame(b.node_id, b.pn_local)
	mut payload := [8]u8{}
	payload[0] = frame.nid
	payload[1] = frame.cbv
	for i in 0 .. 6 {
		payload[2 + i] = u8((frame.pn >> (8 * u64(i))) & 0xFF)
	}
	return payload
}

// parse_udp decodes an 8-byte UDP-NM datagram payload into an nm.Frame.
pub fn parse_udp(data [8]u8) nm.Frame {
	mut pn := u64(0)
	for i in 0 .. 6 {
		pn |= u64(data[2 + i]) << (8 * u64(i))
	}
	return nm.Frame{
		nid: data[0]
		cbv: data[1]
		pn:  pn
	}
}

// process_udp_frame parses an 8-byte incoming UDP-NM datagram payload and feeds it to Nm.
pub fn (b UdpBinding) process(mut n nm.Nm, now u64, data [8]u8) {
	frame := parse_udp(data)
	if frame.nid != b.node_id { // ignore self-received echo
		n.on_frame(now, frame)
	}
}
