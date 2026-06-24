module can

// CAN / CAN-FD driver port.
// Host/sim backend: SocketCAN (see can_socket.c). Target backend: vendor MCAL.
// No heap: frames are fixed-size value types, all buffers static.

#flag -I @VMODROOT/driver/can
#flag @VMODROOT/driver/can/can_socket.c
#include "can_socket.h"

fn C.blob_can_open(&char, int) int
fn C.blob_can_send(int, u32, &u8, u8) int
fn C.blob_can_recv(int, &u32, &u8, &u8) int
fn C.blob_can_close(int)

pub const max_dlc = u8(64)

// A CAN-FD frame. `data` is always 64 bytes; `len` says how many are valid.
pub struct Frame {
pub mut:
	id   u32
	len  u8
	data [64]u8
}

pub struct Channel {
mut:
	sock int = -1
}

// open binds the channel to an interface (e.g. 'vcan0'). Returns false on failure.
pub fn (mut c Channel) open(ifname string, fd_mode bool) bool {
	c.sock = C.blob_can_open(&char(ifname.str), if fd_mode { 1 } else { 0 })
	return c.sock >= 0
}

pub fn (mut c Channel) send(f Frame) bool {
	return C.blob_can_send(c.sock, f.id, &f.data[0], f.len) == 0
}

// recv returns true and fills `f` when a frame is available; false if none.
pub fn (mut c Channel) recv(mut f Frame) bool {
	return C.blob_can_recv(c.sock, &f.id, &f.data[0], &f.len) == 0
}

pub fn (mut c Channel) close() {
	C.blob_can_close(c.sock)
}
