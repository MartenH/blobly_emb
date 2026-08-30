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
fn C.blob_can_send(int, u32, &u8, u8, int) int // last arg = flags: bit0 fd, bit1 ext-id
fn C.blob_can_recv(int, &u32, &u8, &u8, &int) int // last arg = flags out: bit0 fd, bit1 ext-id
fn C.blob_can_tx_ready(int) int
fn C.blob_can_tx_idle(int) int
fn C.blob_can_rx_overruns(int) u32
fn C.blob_can_busoff_recoveries(int) u32
fn C.blob_can_close(int)

pub const max_dlc = u8(64)

// A CAN-FD frame. `data` is always 64 bytes; `len` says how many are valid.
// `ext` = 29-bit extended identifier (vs the 11-bit standard id).
pub struct Frame {
pub mut:
	id   u32
	len  u8
	data [64]u8
	ext  bool
}

// send/recv flag bits shared with the C backends (can_port.h).
const flag_fd = 1
const flag_ext = 2

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
	mut flags := if c.fd { flag_fd } else { 0 }
	if f.ext {
		flags |= flag_ext
	}
	return C.blob_can_send(c.sock, f.id, &f.data[0], f.len, flags) == 0
}

// tx_ready reports whether the Tx path can accept a frame now. A burst sender (the
// ISO-TP dump) gates on this — `for c.tx_ready() && link.poll(...) { c.send(...) }` — so
// it sends at most a FIFO's worth per pass and never blocks the loop/thread. Host
// SocketCAN is always ready (large kernel queue).
pub fn (c Channel) tx_ready() bool {
	return C.blob_can_tx_ready(c.sock) != 0
}

// tx_idle reports wire-done, not software-done: every frame handed to the controller
// has actually been transmitted. A self-resetting node (the boot manager's 0x11) gates
// on this so its last response isn't lost mid-controller (REQ-BOOT-012).
pub fn (c Channel) tx_idle() bool {
	return C.blob_can_tx_idle(c.sock) != 0
}

// recv returns true and fills `f` when a frame is available; false if none.
pub fn (mut c Channel) recv(mut f Frame) bool {
	mut flags := 0
	ok := C.blob_can_recv(c.sock, &f.id, &f.data[0], &f.len, &flags) == 0
	f.ext = (flags & flag_ext) != 0
	return ok
}

// rx_overruns is the number of Rx-overrun EVENTS the driver has seen since open — each
// event is one or more received frames LOST to Rx-buffer overflow (receive-with-loss
// beyond the configured capacity). A monotonic loss indicator (not an exact frame count —
// one hardware overrun flag can cover several dropped frames), surfaced so the upper layer
// can observe it (telemetry/trace) instead of it being silent (REQ-CAN-DRV-008). 0 = none.
pub fn (c Channel) rx_overruns() u32 {
	return C.blob_can_rx_overruns(c.sock)
}

// busoff_recoveries: bus-off events this channel recovered from since open (REQ-CAN-DRV-009).
// 0 on backends where the platform owns recovery (SocketCAN kernel, CanSM above CanIf).
pub fn (c Channel) busoff_recoveries() u32 {
	return C.blob_can_busoff_recoveries(c.sock)
}

pub fn (mut c Channel) close() {
	C.blob_can_close(c.sock)
}
