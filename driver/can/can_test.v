module can

// The SocketCAN backend's frame encoding, through a socket pair standing in for the CAN socket
// (no CAN interface): a 29-bit identifier is carried whole and reported as such, on a classic
// frame and on a 64-byte CAN-FD frame, and an 11-bit frame of the same id number stays 11-bit.
// What the kernel's CAN layer does with the frame is not exercised; the FDCAN backends are
// verified on silicon (requirements/can-drv.toml).
// @verifies REQ-CAN-DRV-010

#include <sys/socket.h>

fn C.socketpair(int, int, int, &i32) int

// pair: two connected ends that keep each frame's boundary, as a CAN socket does
fn pair(fd bool) (Channel, Channel) {
	mut fds := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_SEQPACKET, 0, &fds[0]) == 0
	return Channel{
		sock: int(fds[0])
		fd:   fd
	}, Channel{
		sock: int(fds[1])
		fd:   fd
	}
}

// read: the next frame as the backend reports it, with its flags
fn read(c Channel) (u32, []u8, int) {
	mut id := u32(0)
	mut len := u8(0)
	mut data := [64]u8{}
	mut flags := 0
	assert C.blob_can_recv(c.sock, &id, &data[0], &len, &flags) == 0
	return id, data[..int(len)].clone(), flags
}

fn frame(id u32, ext bool, n int) Frame {
	mut f := Frame{
		id:  id
		len: u8(n)
		ext: ext
	}
	for i in 0 .. n {
		f.data[i] = u8(i * 7 + 1)
	}
	return f
}

fn test_a_29_bit_identifier_on_a_classic_frame() {
	mut tx, mut rx := pair(false)
	defer {
		tx.close()
		rx.close()
	}
	assert tx.send(frame(0x18DA_F110, true, 8))
	id, data, flags := read(rx)
	assert id == 0x18DA_F110
	assert flags & flag_ext != 0
	assert flags & flag_fd == 0
	assert data == frame(0x18DA_F110, true, 8).data[..8]
}

fn test_a_29_bit_identifier_on_a_64_byte_fd_frame() {
	mut tx, mut rx := pair(true)
	defer {
		tx.close()
		rx.close()
	}
	assert tx.send(frame(0x18DA_F110, true, 64))
	id, data, flags := read(rx)
	assert id == 0x18DA_F110
	assert flags & flag_ext != 0
	assert flags & flag_fd != 0
	assert data == frame(0x18DA_F110, true, 64).data[..]
}

fn test_the_identifier_format_survives_the_channel() {
	mut tx, mut rx := pair(true)
	defer {
		tx.close()
		rx.close()
	}
	assert tx.send(frame(0x7B0, true, 12))
	assert tx.send(frame(0x7B0, false, 12))
	mut f := Frame{}
	assert rx.recv(mut f)
	assert f.id == 0x7B0 && f.ext && f.len == 12
	assert rx.recv(mut f)
	assert f.id == 0x7B0 && !f.ext && f.len == 12
}
