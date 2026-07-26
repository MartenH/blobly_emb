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
	a := emit_bulk_glue(pools, pm).join('\n')
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
	a := emit_bulk_glue(pools, pm).join('\n')
	// no per-image arena — the pool IS the shared window bytes, derived from duo.h
	assert !a.contains('g_bulk_lidar_arena')
	assert a.contains('#include "duo.h"')
	assert a.contains('fn C.duo_bulk_addr() usize')
	// first (and only) cross-core pool sits at offset 0 from the base
	assert a.contains('voidptr(C.duo_bulk_addr() + usize(0))')
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
	a := emit_bulk_glue(pools, pm).join('\n')
	assert a.contains('voidptr(C.duo_bulk_addr() + usize(${off0}))')
	assert a.contains('voidptr(C.duo_bulk_addr() + usize(${off1}))')
}
