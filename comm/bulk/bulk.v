// bulk: the V face of boards/common/bulk.h, the bulk transport pool (docs/bulk-transport.md) —
// what generated images call for their pools. A module of its own because the header is the one
// C include generated code needs, and V3 stops declaring a module's C functions once a file in it
// includes a header (it takes the header to declare them): in the generated `gen` module that
// silenced the declaration of every other glue function the image calls.
module bulk

// boards/common is on the target C path (BOARD_INCS); a host build compiles from the repo root,
// so the include is anchored at the v.mod root
#flag -I @VMODROOT/boards/common
#include "bulk.h"

pub struct C.bulk_t {}

fn C.bulk_init(b &C.bulk_t, nbuf u32, bufsz u32)
fn C.bulk_valid(b &C.bulk_t) int
fn C.bulk_loan(b &C.bulk_t) int
fn C.bulk_publish(b &C.bulk_t, idx u32, len u32)
fn C.bulk_ready(b &C.bulk_t) u32
fn C.bulk_take(b &C.bulk_t, len &u32) int
fn C.bulk_release(b &C.bulk_t, idx u32)
fn C.bulk_buf(b &C.bulk_t, idx u32) &u8
fn C.bulk_overflows(b &C.bulk_t) u32

@[inline]
pub fn init(b &C.bulk_t, nbuf u32, bufsz u32) {
	C.bulk_init(b, nbuf, bufsz)
}

@[inline]
pub fn valid(b &C.bulk_t) bool {
	return C.bulk_valid(b) != 0
}

@[inline]
pub fn loan(b &C.bulk_t) int {
	return C.bulk_loan(b)
}

@[inline]
pub fn publish(b &C.bulk_t, idx u32, len u32) {
	C.bulk_publish(b, idx, len)
}

@[inline]
pub fn ready(b &C.bulk_t) u32 {
	return C.bulk_ready(b)
}

@[inline]
pub fn take(b &C.bulk_t, len &u32) int {
	return C.bulk_take(b, len)
}

@[inline]
pub fn release(b &C.bulk_t, idx u32) {
	C.bulk_release(b, idx)
}

@[inline]
pub fn buf(b &C.bulk_t, idx u32) &u8 {
	return C.bulk_buf(b, idx)
}

@[inline]
pub fn overflows(b &C.bulk_t) u32 {
	return C.bulk_overflows(b)
}
