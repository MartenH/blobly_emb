module nm_udp

import comm.nm

// nm_udp — UDP Network Management binding over comm/nm (docs/someip.md, docs/nm.md).
// Transmits and receives NM frames as UDP datagrams over Ethernet.

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

// encode_udp_frame returns the 8-byte NM payload for UDP transmission.
pub fn (b UdpBinding) encode(n &nm.Nm) [8]u8 {
	frame := n.build_frame(b.node_id, b.pn_local)
	return frame.to_bytes()
}

// process_udp_frame parses an 8-byte incoming UDP-NM datagram and feeds it to Nm.
pub fn (b UdpBinding) process(mut n nm.Nm, now u64, data [8]u8) {
	frame := nm.parse_frame(data)
	if frame.nid != b.node_id { // ignore self-received echo
		n.on_frame(now, frame)
	}
}
