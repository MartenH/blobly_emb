module nm

// nm_udp — UDP Network Management binding over comm/nm (docs/someip.md, docs/nm.md).
// Transmits and receives NM frames as UDP datagrams over Ethernet.

pub struct UdpBinding {
pub mut:
	node_id  u8
	pn_local u64
	port     u16 = 30490
}

// encode_udp_frame returns the 8-byte NM payload for UDP transmission.
pub fn (b UdpBinding) encode(nm &Nm) [8]u8 {
	frame := nm.build_frame(b.node_id, b.pn_local)
	return frame.to_bytes()
}

// process_udp_frame parses an 8-byte incoming UDP-NM datagram and feeds it to Nm.
pub fn (b UdpBinding) process(mut nm Nm, now u64, data [8]u8) {
	frame := parse_frame(data)
	if frame.nid != b.node_id { // ignore self-received echo
		nm.on_frame(now, frame)
	}
}
