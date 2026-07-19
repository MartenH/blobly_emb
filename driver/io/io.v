module io

// IO driver port. One narrow contract (io_port.h), backends selected at build
// time in io_backend.c:
//   (default)          file mirror io/<name>  — host / sim
//   -DBLOB_IO_STM32    board pin table        — target (bench phase)
// Channels are generator-assigned indexes (0..N-1); no heap, all state static.

#flag -I @VMODROOT/driver/io
#flag @VMODROOT/driver/io/io_backend.c
#include "io_port.h"

fn C.blob_io_cfg(int, &char, &char, int, u32) int
fn C.blob_io_init() int
fn C.blob_io_gpio_read(int) int
fn C.blob_io_gpio_read_checked(int, &int) int
fn C.blob_io_gpio_write(int, int)
fn C.blob_io_close()

// cfg declares one point before init: channel, signal name, board pin,
// direction, and the pre-publication init level. Returns false on failure.
pub fn cfg(ch int, name string, pin string, output bool, init u32) bool {
	return C.blob_io_cfg(ch, &char(name.str), &char(pin.str), if output { 1 } else { 0 },
		init) == 0
}

// init opens the backend and applies every output's init level FIRST — before
// any app code runs, so no pin glitches through its reset state into an
// active-high actuator (REQ-IO-009). The io thread only ever re-applies.
pub fn init() bool {
	return C.blob_io_init() == 0
}

// gpio_read returns the point's current level. Wait-free by contract
// (REQ-IO-008): bounded work, never blocks — a backend failure serves the
// last-good value instead of an error the loop would have to handle.
pub fn gpio_read(ch int) bool {
	return C.blob_io_gpio_read(ch) != 0
}

// gpio_read_checked returns the level only when the backend parsed a REAL
// value — none otherwise, never last-good: the boot publish must not fabricate
// an initial sample (docs/io.md startup ordering; the periodic reads keep
// gpio_read's last-good semantics).
pub fn gpio_read_checked(ch int) ?bool {
	v := 0
	if C.blob_io_gpio_read_checked(ch, &v) != 0 {
		return none
	}
	return v != 0
}

// gpio_write drives an output point.
pub fn gpio_write(ch int, level bool) {
	C.blob_io_gpio_write(ch, if level { 1 } else { 0 })
}

// close releases the backend; points must be re-declared before another init.
pub fn close() {
	C.blob_io_close()
}
