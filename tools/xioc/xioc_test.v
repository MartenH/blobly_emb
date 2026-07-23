module main

// @verifies REQ-INV-002
// The WIDE xioc channel under a concurrent writer, on the host (the XIOC_DMB seam makes the
// header compile off-Arm for the first time, so the plain-store discipline is CI-tested).
// The contract under test is the location-transparency fix: a signal up to one PDU (64 B)
// crosses cores tear-free and wait-free — every value the reader commits is one complete
// publish (word[i] == word[0] + i by construction), never a blend of two.
//
// Every assertion here is INTERLEAVING-INDEPENDENT: the writer publishes a FIXED count and
// the reader must (a) never commit a torn value, (b) only move forward, and (c) observe the
// final value once the writer has joined — all guaranteed by the mechanism regardless of how
// a loaded 2-core CI runner schedules the threads. (v1 asserted a fresh-read COUNT from two
// racing threads and failed on exactly that runner with fresh = 1 — a scheduling assert, not
// a mechanism assert.)
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
const publishes = u32(100_000) // fixed writer work: the test's end state is deterministic

__global (
	g_cell [64]u64 // 512 B backing for the channel (header + 4 slots × 11 words), 8-aligned
)

fn writer() {
	mut src := [16]u32{}
	for n in u32(1) .. publishes + 1 {
		for i in 0 .. int(words) {
			src[i] = n + u32(i) // the consistency invariant: word[i] - word[0] == i
		}
		C.xioc_n_write(&g_cell[0], &src[0])
	}
}

fn test_wide_channel_never_tears_under_concurrent_writer() {
	C.xioc_n_init(&g_cell[0], words)
	t := spawn writer()

	mut rd_seq := u32(0)
	mut dst := [16]u32{}
	mut fresh := u64(0)
	mut last_base := u32(0)
	// race phase: poll while the writer runs. However the scheduler slices this, every
	// committed value must be complete and ordering must only move forward.
	for _ in 0 .. 300_000 {
		if C.xioc_n_read(&g_cell[0], &rd_seq, &dst[0]) != 0 {
			fresh++
			for i in 1 .. int(words) {
				assert dst[i] - dst[0] == u32(i), 'torn read: word ${i} of base ${dst[0]}'
			}
			assert dst[0] > last_base, 'freshness went backwards: ${dst[0]} after ${last_base}'
			last_base = dst[0]
		}
	}
	t.wait()

	// deterministic end state: the writer has fully joined, so its LAST publish is the
	// channel's latest — one more read must surface it (fresh, complete, final).
	if last_base != publishes {
		assert C.xioc_n_read(&g_cell[0], &rd_seq, &dst[0]) == 1, 'final value must be readable after the writer joined'
		for i in 1 .. int(words) {
			assert dst[i] - dst[0] == u32(i), 'torn FINAL read: word ${i}'
		}
		last_base = dst[0]
	}
	assert last_base == publishes, 'the reader must end on the final publish (got ${last_base})'
	assert fresh >= 1 // at least the final observation is guaranteed on any scheduler

	// last-good retention: nothing new published — not fresh, buffer untouched.
	assert C.xioc_n_read(&g_cell[0], &rd_seq, &dst[0]) == 0
	assert dst[0] == publishes
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
