module main

// @verifies REQ-INV-002
// The WIDE xioc channel under a max-rate writer, on the host (the XIOC_DMB seam makes the
// header compile off-Arm for the first time, so the plain-store discipline is CI-tested).
// The contract under test is the location-transparency fix: a signal up to one PDU (64 B)
// crosses cores tear-free and wait-free — every value the reader commits is one complete
// publish (word[i] == word[0] + i by construction), never a blend of two.
//
// Honesty note: x86's memory model is stronger than two Cortex cores over an AXI fabric,
// so a green run here proves the LOGIC (staging, seq recheck, last-good retention), not
// the silicon. The H755 re-run of the 2026-07-12 tear harness at the new widths is in the
// bench queue.

#flag -I @VMODROOT/boards/common
#include "xioc.h"

fn C.xioc_n_init(c voidptr, words u32)
fn C.xioc_n_write(c voidptr, src &u32)
fn C.xioc_n_read(c voidptr, rd_seq &u32, dst &u32) int

const words = u32(10) // 40 B — the size from the conversation that prompted the widening

__global (
	g_cell   [64]u64 // 512 B backing for the channel (header + 4 slots × 11 words), 8-aligned
	g_stop   bool
	g_writes u64
)

fn writer() {
	mut src := [16]u32{}
	for !g_stop {
		g_writes++
		n := u32(g_writes)
		for i in 0 .. int(words) {
			src[i] = n + u32(i) // the consistency invariant: word[i] - word[0] == i
		}
		C.xioc_n_write(&g_cell[0], &src[0])
	}
}

fn test_wide_channel_never_tears_under_max_rate_writer() {
	C.xioc_n_init(&g_cell[0], words)
	t := spawn writer()

	mut rd_seq := u32(0)
	mut dst := [16]u32{}
	mut fresh := u64(0)
	mut last_base := u32(0)
	for _ in 0 .. 300_000 {
		if C.xioc_n_read(&g_cell[0], &rd_seq, &dst[0]) != 0 {
			fresh++
			// completeness: exactly one publish, never a blend of two
			for i in 1 .. int(words) {
				assert dst[i] - dst[0] == u32(i), 'torn read: word ${i} of ${dst[0]}'
			}
			// freshness only moves forward
			assert dst[0] >= last_base
			last_base = dst[0]
		}
	}
	g_stop = true
	t.wait()

	assert fresh > 1000, 'liveness: a max-rate writer must yield fresh reads (got ${fresh})'
	assert g_writes > 10_000
	// the reader still holds the last committed value after the writer stopped
	assert dst[0] == last_base
}

// The original {a,b} pair API is untouched bench-verified glue (H755 comm_glue/m4_glue) —
// pin that it still behaves: publish/consume, freshness edge, last-good retention.
fn C.xioc_init(c voidptr)
fn C.xioc_write(c voidptr, a u32, b u32)
fn C.xioc_read(c voidptr, rd voidptr) int

fn test_pair_api_compat() {
	mut cell := [12]u64{} // 96 B: one xioc_t
	mut rd := [3]u32{} // xioc_rd_t{seq,a,b}
	C.xioc_init(&cell[0])
	assert C.xioc_read(&cell[0], &rd[0]) == 0 // nothing published yet
	C.xioc_write(&cell[0], 7, 11)
	assert C.xioc_read(&cell[0], &rd[0]) == 1
	assert rd[1] == 7 && rd[2] == 11
	assert C.xioc_read(&cell[0], &rd[0]) == 0 // consumed: not fresh twice
	assert rd[1] == 7 && rd[2] == 11 // but the value is retained
}
