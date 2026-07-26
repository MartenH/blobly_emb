module main

// Bulk placement guards: an INTRA-core pool gets a per-image global arena; a CROSS-CORE pool
// (producer/consumer on different cores) is placed at a fixed address in the H755 shared window
// so both images address the SAME bytes. The target cross-build is not gated in CI, so the
// codegen is checked here.

// a PartMap with two partitions: `hot` on core 0 (CM7), `cool` on core 1 (CM4, a satellite image).
fn duo_partmap() PartMap {
	return PartMap{
		core_of:     {
			'hot':  0
			'cool': 1
		}
		thread_part: {
			'hot_t':  'hot'
			'cool_t': 'cool'
		}
		image:       {
			'cool': '../h755_m4_app'
		}
	}
}

fn test_bulk_ep_core_resolves_partition_or_thread() {
	pm := duo_partmap()
	// endpoint may be named by its partition...
	assert bulk_ep_core('hot', pm) == 0
	assert bulk_ep_core('cool', pm) == 1
	// ...or by a thread inside it.
	assert bulk_ep_core('hot_t', pm) == 0
	assert bulk_ep_core('cool_t', pm) == 1
	// unknown endpoint defaults to core 0 (single-image case).
	assert bulk_ep_core('nope', pm) == 0
}

fn test_intra_core_pool_uses_local_global_arena() {
	pm := duo_partmap()
	pools := [BulkPoolCfg{
		name:     'cam'
		producer: 'hot'
		consumer: 'hot_t' // same core -> intra-core
		bufsz:    64
		nbuf:     2
	}]
	assert !bulk_cross_core(pools[0], pm)
	a := emit_bulk_glue(pools, pm, '').join('\n')
	// a per-image arena + a ptr into it, NOT the shared window
	assert a.contains('__global (')
	assert a.contains('g_bulk_cam_arena')
	assert a.contains('&C.bulk_t(&g_bulk_cam_arena[0])')
	assert !a.contains('duo_bulk_addr')
	assert !a.contains('#include "duo.h"')
}

fn test_cross_core_pool_lives_in_shared_window() {
	pm := duo_partmap()
	pools := [BulkPoolCfg{
		name:     'lidar'
		producer: 'hot'  // core 0
		consumer: 'cool' // core 1 -> cross-core
		bufsz:    128
		nbuf:     4
	}]
	assert bulk_cross_core(pools[0], pm)
	a := emit_bulk_glue(pools, pm, '').join('\n')
	// no per-image arena — the pool IS the shared window bytes, derived from the platform base
	assert !a.contains('g_bulk_lidar_arena')
	// generated code stays board-agnostic: it externs the platform seam, never includes a board header
	assert !a.contains('#include "duo.h"')
	assert a.contains('fn C.duo_bulk_base() usize')
	// first (and only) cross-core pool sits at offset 0 from the base
	assert a.contains('voidptr(C.duo_bulk_base() + usize(0))')
	// the public wrappers still exist and route through the shared ptr
	assert a.contains('pub fn bulk_lidar_init()')
	assert a.contains('C.bulk_init(bulk_lidar_ptr()')
}

fn test_cross_core_pools_pack_32b_aligned_in_order() {
	pm := duo_partmap()
	// two cross-core pools: the second's offset = ceil(bulk_bytes(first)/32)*32
	pools := [
		BulkPoolCfg{
			name:     'first'
			producer: 'hot'
			consumer: 'cool'
			bufsz:    50 // deliberately non-32-multiple to exercise alignment
			nbuf:     1
		},
		BulkPoolCfg{
			name:     'second'
			producer: 'cool'
			consumer: 'hot'
			bufsz:    32
			nbuf:     1
		},
	]
	off0 := 0
	off1 := (bulk_bytes(1, 50) + 31) & ~31
	assert off1 % 32 == 0
	a := emit_bulk_glue(pools, pm, '').join('\n')
	assert a.contains('voidptr(C.duo_bulk_base() + usize(${off0}))')
	assert a.contains('voidptr(C.duo_bulk_base() + usize(${off1}))')
}

fn test_satellite_emits_only_its_shared_pools_at_the_owner_offset() {
	pm := duo_partmap()
	pools := [
		// an owner-local pool (both ends on core 0) — must NOT reach the satellite image
		BulkPoolCfg{
			name:     'local'
			producer: 'hot'
			consumer: 'hot_t'
			bufsz:    32
			nbuf:     1
		},
		// a shared pool the satellite is the consumer of — offset is AFTER 'local' is skipped?
		// no: the offset map counts only CROSS-CORE pools, so 'shared' sits at offset 0.
		BulkPoolCfg{
			name:     'shared'
			producer: 'hot'
			consumer: 'cool'
			bufsz:    64
			nbuf:     2
		},
	]
	sat := emit_bulk_glue(pools, pm, 'cool').join('\n')
	// the satellite gets the shared pool — as the CONSUMER ('cool' is the consumer), so it emits
	// the take side, NOT the producer's init/loan/publish (capability split).
	assert sat.contains('pub fn bulk_shared_take(')
	assert sat.contains('pub fn bulk_shared_valid()')
	assert !sat.contains('pub fn bulk_shared_init()')
	assert !sat.contains('pub fn bulk_shared_loan()')
	assert sat.contains('fn C.duo_bulk_base() usize')
	assert !sat.contains('#include "duo.h"')
	// ...at the SAME offset the owner computed (0 — 'local' is intra-core, not in the window)...
	assert sat.contains('voidptr(C.duo_bulk_base() + usize(0))')
	// ...and NEVER the owner's intra-core global.
	assert !sat.contains('g_bulk_local_arena')
	assert !sat.contains('bulk_local_init')
	// a satellite that touches no shared pool emits nothing at all.
	none_pm := PartMap{
		core_of:     {
			'hot': 0
			'x':   1
		}
		thread_part: {}
	}
	empty := emit_bulk_glue([pools[0]], none_pm, 'x')
	assert empty.len == 0
}

fn test_capability_split_by_role() {
	pm := duo_partmap()
	// cross-core: producer on the owner (hot/core 0), consumer on the satellite (cool/core 1)
	xfer := [BulkPoolCfg{
		name:     'xfer'
		producer: 'hot'
		consumer: 'cool'
		bufsz:    256
		nbuf:     4
	}]
	owner := emit_bulk_glue(xfer, pm, '').join('\n')
	// the OWNER is the producer: free/publish side only
	assert owner.contains('pub fn bulk_xfer_init()')
	assert owner.contains('pub fn bulk_xfer_loan()')
	assert owner.contains('pub fn bulk_xfer_publish(')
	assert owner.contains('pub fn bulk_xfer_overflows()')
	assert owner.contains('pub fn bulk_xfer_buf(') // shared
	assert !owner.contains('pub fn bulk_xfer_take(')
	assert !owner.contains('pub fn bulk_xfer_release(')
	assert !owner.contains('pub fn bulk_xfer_valid()')

	sat := emit_bulk_glue(xfer, pm, 'cool').join('\n')
	// the SATELLITE is the consumer: take/release side only
	assert sat.contains('pub fn bulk_xfer_valid()')
	assert sat.contains('pub fn bulk_xfer_ready()')
	assert sat.contains('pub fn bulk_xfer_take(')
	assert sat.contains('pub fn bulk_xfer_release(')
	assert sat.contains('pub fn bulk_xfer_buf(') // shared
	assert !sat.contains('pub fn bulk_xfer_init()')
	assert !sat.contains('pub fn bulk_xfer_loan()')
	assert !sat.contains('pub fn bulk_xfer_publish(')

	// an INTRA-core pool has both ends in one image -> the FULL API (both roles).
	intra := [BulkPoolCfg{
		name:     'cam'
		producer: 'hot'
		consumer: 'hot_t'
		bufsz:    64
		nbuf:     2
	}]
	full := emit_bulk_glue(intra, pm, '').join('\n')
	assert full.contains('pub fn bulk_cam_init()')   // producer op
	assert full.contains('pub fn bulk_cam_take(')    // consumer op
	assert full.contains('pub fn bulk_cam_publish(')
	assert full.contains('pub fn bulk_cam_release(')

	// MIRROR (the real demo's topology): producer on the SATELLITE, consumer on the OWNER.
	// The roles must follow the endpoints, not the owner/satellite kind.
	mir := [BulkPoolCfg{
		name:     'up'
		producer: 'cool' // satellite produces
		consumer: 'hot'  // owner consumes
		bufsz:    128
		nbuf:     2
	}]
	o := emit_bulk_glue(mir, pm, '').join('\n') // owner = CONSUMER
	assert o.contains('pub fn bulk_up_take(')
	assert o.contains('pub fn bulk_up_valid()')
	assert !o.contains('pub fn bulk_up_init()')
	assert !o.contains('pub fn bulk_up_loan()')
	s := emit_bulk_glue(mir, pm, 'cool').join('\n') // satellite = PRODUCER
	assert s.contains('pub fn bulk_up_init()')
	assert s.contains('pub fn bulk_up_loan()')
	assert !s.contains('pub fn bulk_up_take(')
	assert !s.contains('pub fn bulk_up_valid()')
}

fn test_satellite_local_intra_pool_stays_in_the_satellite() {
	// An INTRA-core pool whose endpoints both live in a SATELLITE partition must be emitted by
	// the SATELLITE image (where its FBs run), not dumped into the owner's core-0 BSS.
	pm := duo_partmap() // 'cool' is core 1 with image = "../h755_m4_app"
	pools := [BulkPoolCfg{
		name:     'satcam'
		producer: 'cool'
		consumer: 'cool_t' // both resolve to partition 'cool' (core 1) => intra-core, satellite-owned
		bufsz:    32
		nbuf:     1
	}]
	assert !bulk_cross_core(pools[0], pm)
	// the OWNER must NOT emit it — neither endpoint is an owner-local partition
	owner := emit_bulk_glue(pools, pm, '')
	assert owner.len == 0
	// the SATELLITE emits it as its own per-image arena (intra-core, no shared window)
	sat := emit_bulk_glue(pools, pm, 'cool').join('\n')
	assert sat.contains('g_bulk_satcam_arena')
	assert sat.contains('pub fn bulk_satcam_init()')
	assert !sat.contains('duo_bulk_base')
}

fn test_owner_and_satellite_agree_on_a_nonzero_shared_offset() {
	// The strong form of the cross-image invariant: a satellite that is an endpoint of ONLY the
	// second cross-core pool must still place it at the owner's NON-ZERO offset (behind the
	// first). Needs a second satellite core so 'first' does not also touch 'cool'.
	pm := PartMap{
		core_of:     {
			'hot':  0
			'cool': 1
			'cold': 2
		}
		thread_part: {}
		image:       {
			'cool': '../a'
			'cold': '../b'
		}
	}
	pools := [
		BulkPoolCfg{
			name:     'first'
			producer: 'hot'
			consumer: 'cold' // core 0 <-> core 2, offset 0 — 'cool' is NOT an endpoint
			bufsz:    64
			nbuf:     2
		},
		BulkPoolCfg{
			name:     'second'
			producer: 'hot'
			consumer: 'cool' // core 0 <-> core 1, sits behind 'first'
			bufsz:    32
			nbuf:     1
		},
	]
	off1 := (bulk_bytes(2, 64) + 31) & ~31
	assert off1 > 0
	owner := emit_bulk_glue(pools, pm, '').join('\n')
	sat := emit_bulk_glue(pools, pm, 'cool').join('\n')
	// owner and satellite derive 'second' at the SAME non-zero offset
	assert owner.contains('voidptr(C.duo_bulk_base() + usize(${off1}))')
	assert sat.contains('voidptr(C.duo_bulk_base() + usize(${off1}))')
	// the satellite emits ONLY 'second' (it is not an endpoint of 'first')
	assert sat.contains('bulk_second_ptr')
	assert !sat.contains('bulk_first')
}
