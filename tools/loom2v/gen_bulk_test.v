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
	// the satellite gets the shared pool...
	assert sat.contains('pub fn bulk_shared_init()')
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
