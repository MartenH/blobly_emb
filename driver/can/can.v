module can

// CAN / CAN-FD driver port. One narrow contract (can_port.h), three backends
// selected at build time in can_backend.c:
//   (default)          SocketCAN over vcan   — host / sim
//   -DBLOB_CAN_STHAL   STM32 H7 FDCAN (HAL)  — bare-metal / no AUTOSAR
//   -DBLOB_CAN_CANIF   above AUTOSAR CanIf    — vendor BSW (CDD)
// No heap: frames are fixed-size value types, all buffers static.

#flag -I @VMODROOT/driver/can
#flag @VMODROOT/driver/can/can_backend.c
#include "can_port.h"

fn C.blob_can_open(&char, int) int
fn C.blob_can_send(int, u32, &u8, u8, int) int
fn C.blob_can_recv(int, &u32, &u8, &u8) int
fn C.blob_can_tx_ready(int) int
fn C.blob_can_rx_overruns(int) u32
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
	fd   bool // CAN-FD (canfd_frame) vs classic (can_frame) on the wire
}

// open binds the channel to an interface (e.g. 'vcan0'). Returns false on failure.
pub fn (mut c Channel) open(ifname string, fd_mode bool) bool {
	c.sock = C.blob_can_open(&char(ifname.str), if fd_mode { 1 } else { 0 })
	c.fd = fd_mode
	return c.sock >= 0
}

pub fn (mut c Channel) send(f Frame) bool {
	return C.blob_can_send(c.sock, f.id, &f.data[0], f.len, if c.fd { 1 } else { 0 }) == 0
}

// tx_ready reports whether the Tx path can accept a frame now. A burst sender (the
// ISO-TP dump) gates on this — `for c.tx_ready() && link.poll(...) { c.send(...) }` — so
// it sends at most a FIFO's worth per pass and never blocks the loop/thread. Host
// SocketCAN is always ready (large kernel queue).
pub fn (c Channel) tx_ready() bool {
	return C.blob_can_tx_ready(c.sock) != 0
}

// recv returns true and fills `f` when a frame is available; false if none.
pub fn (mut c Channel) recv(mut f Frame) bool {
	return C.blob_can_recv(c.sock, &f.id, &f.data[0], &f.len) == 0
}

// rx_overruns is the number of Rx-overrun EVENTS the driver has seen since open — each
// event is one or more received frames LOST to Rx-buffer overflow (receive-with-loss
// beyond the configured capacity). A monotonic loss indicator (not an exact frame count —
// one hardware overrun flag can cover several dropped frames), surfaced so the upper layer
// can observe it (telemetry/trace) instead of it being silent (REQ-CAN-DRV-008). 0 = none.
pub fn (c Channel) rx_overruns() u32 {
	return C.blob_can_rx_overruns(c.sock)
}

pub fn (mut c Channel) close() {
	C.blob_can_close(c.sock)
}
