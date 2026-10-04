module eth

// The Ethernet source of a received IPv4 frame (driver/eth/arp_glean.h), which doip_netx.c records
// as the requester's ARP entry so the first DoIP answer does not wait on ARP (#368).

#include "arp_glean.h"

fn C.arp_glean_source(&u8, &u8, &u8, &u32, &u32) int

const board = [u8(0x02), 0, 0, 0, 0, 1]

// a frame as the driver leaves it: two bytes of alignment pad, the Ethernet header, an IP header
fn frame_to(dst []u8, src []u8, ether_type u16) []u8 {
	mut f := [u8(0), 0]
	f << dst
	f << src
	f << [u8(ether_type >> 8), u8(ether_type)]
	f << [u8(0x45), 0, 0, 28] // the IP header begins
	return f
}

fn frame(src []u8, ether_type u16) []u8 {
	return frame_to(board, src, ether_type)
}

fn glean(f []u8, ip_off int) (int, u32, u32) {
	mut msw := u32(0)
	mut lsw := u32(0)
	ok := C.arp_glean_source(&f[0], unsafe { &f[ip_off] }, &board[0], &msw, &lsw)
	return ok, msw, lsw
}

fn test_the_source_mac_is_read_in_netx_split() {
	f := frame([u8(0x00), 0x15, 0x5D, 0xA1, 0xB2, 0xC3], 0x0800)
	ok, msw, lsw := glean(f, 16)
	assert ok == 1
	assert msw == 0x0015
	assert lsw == 0x5DA1B2C3
}

fn test_only_an_ipv4_frame_is_read() {
	ok, _, _ := glean(frame([u8(0x00), 0x15, 0x5D, 0xA1, 0xB2, 0xC3], 0x86DD), 16)
	assert ok == 0
}

fn test_a_group_or_empty_source_is_not_an_address() {
	mut ok, _, _ := glean(frame([u8(0x01), 0x00, 0x5E, 0, 0, 1], 0x0800), 16)
	assert ok == 0
	ok, _, _ = glean(frame([u8(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], 0x0800), 16)
	assert ok == 0
	ok, _, _ = glean(frame([u8(0), 0, 0, 0, 0, 0], 0x0800), 16)
	assert ok == 0
}

fn test_a_header_outside_the_buffer_is_not_read() {
	f := frame([u8(0x00), 0x15, 0x5D, 0xA1, 0xB2, 0xC3], 0x0800)
	mut ok, _, _ := glean(f, 13) // 13 bytes in front: the header would start before the buffer
	assert ok == 0
	ok, _, _ = glean(f, 14) // 14: in bounds, but those bytes are not this frame's header
	assert ok == 0
}

fn test_only_a_frame_addressed_to_this_station_is_read() {
	src := [u8(0x00), 0x15, 0x5D, 0xA1, 0xB2, 0xC3]
	mut ok, _, _ := glean(frame_to([u8(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], src, 0x0800), 16)
	assert ok == 1 // a broadcast request (identification to the subnet)
	ok, _, _ = glean(frame_to([u8(0x02), 0, 0, 0, 0, 2], src, 0x0800), 16)
	assert ok == 0 // another station's: these bytes are not the frame that carried this header
}
