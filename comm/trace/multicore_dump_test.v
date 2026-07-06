module trace

import comm.isotp


// pump_dump drives PDUs between a tx and rx Link until quiescent (the id-routing a bus
// bridge does), at a fixed `now`.
fn pump_dump(mut tx isotp.Link, mut rx isotp.Link, now u64) {
	for _ in 0 .. 4000 {
		mut p := isotp.Pdu{}
		if tx.poll(now, mut p) {
			rx.on_frame(now, p)
			continue
		}
		if rx.poll(now, mut p) {
			tx.on_frame(now, p)
			continue
		}
		break
	}
}

// send_block packs a core's dump block, streams it through an ISO-TP Link pair, and copies
// the reassembled bytes into `out`; returns the reassembled length.
fn send_block(mut b TraceBuffer, core u8, out &u8) int {
	mut blk := [128]u8{}
	n := b.pack_block(&blk[0], 128, core)
	mut tx := isotp.Link{}
	mut rx := isotp.Link{}
	assert tx.send(&blk[0], n)
	pump_dump(mut tx, mut rx, 1000)
	return rx.take(out)
}

// A per-core dump block survives ISO-TP segmentation/reassembly and decodes back to its
// self-describing header (core + count) plus the mixed run/switch records — two cores
// yielding two distinct, self-identifying blocks: the multi-core read-out path end to end.
fn test_multicore_dump_roundtrip() {
	mut backing0 := [8]Record{}
	mut backing1 := [8]Record{}
	mut b0 := new_buffer(&backing0[0], 8, .oneshot, 0)
	mut b1 := new_buffer(&backing1[0], 8, .oneshot, 0)
	b0.start()
	b0.push(Record{ handler_id: 5 })
	b0.push(new_switch(100, 0, 1, switch_preempt)) // a swimlane event mixed into the run records
	b0.push(Record{ handler_id: 6 })
	b1.start()
	b1.push(Record{ handler_id: 9 })

	// core 3's block (from b0)
	mut g0 := [128]u8{}
	m0 := send_block(mut b0, 3, &g0[0])
	assert m0 == 8 * 4 // header + 3 records
	h0 := decode_record(first8(g0))
	assert h0.is_header() && h0.header_core() == 3 && h0.header_count() == 3
	sw := decode_record(at8(g0, 16)) // 2nd record is the switch
	assert sw.is_switch() && sw.from_thread() == 0 && sw.to_thread() == 1
	assert sw.reason() == switch_preempt

	// core 5's block (from b1) — a different, self-identifying header
	mut g1 := [128]u8{}
	m1 := send_block(mut b1, 5, &g1[0])
	assert m1 == 8 * 2 // header + 1 record
	h1 := decode_record(first8(g1))
	assert h1.is_header() && h1.header_core() == 5 && h1.header_count() == 1
	assert decode_record(at8(g1, 8)).handler_id == 9
}

fn first8(a [128]u8) [8]u8 {
	return at8(a, 0)
}

fn at8(a [128]u8, off int) [8]u8 {
	mut b := [8]u8{}
	for i in 0 .. 8 {
		b[i] = a[off + i]
	}
	return b
}
