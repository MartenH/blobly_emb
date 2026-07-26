// loom2v's BULK codegen — static pool allocation and V wrapper APIs for bulk endpoints (docs/bulk-transport.md).
module main

import toml
import tools.ecumodel

struct BulkPoolCfg {
pub mut:
	name     string
	producer string
	consumer string
	bufsz    int
	nbuf     int
}

fn parse_bulk(doc toml.Doc) []BulkPoolCfg {
	mut pools := []BulkPoolCfg{}
	for b in ecumodel.toml_arr(doc, 'bulk') {
		bm := b.as_map()
		name := (bm['name'] or { toml.Any('') }).string()
		if name == '' {
			continue
		}
		pools << BulkPoolCfg{
			name:     name
			producer: (bm['producer'] or { toml.Any('') }).string()
			consumer: (bm['consumer'] or { toml.Any('') }).string()
			bufsz:    int((bm['bufsz'] or { toml.Any(0) }).int())
			nbuf:     int((bm['nbuf'] or { toml.Any(0) }).int())
		}
	}
	return pools
}

// bulk_bytes = BULK_BYTES(nbuf, bufsz): the exact pool footprint (header + rings + buffers).
fn bulk_bytes(nbuf int, bufsz int) int {
	return 96 + (((3 * 4 * nbuf) + 31) & ~31) + nbuf * bufsz
}

// bulk_ep_part resolves a [[bulk]] producer/consumer endpoint (a partition OR a thread name)
// to its owning partition.
fn bulk_ep_part(ep string, part PartMap) string {
	return if ep in part.core_of { ep } else { part.thread_part[ep] or { ep } }
}

// bulk_ep_core resolves an endpoint to its core, so a pool whose two ends sit on different
// cores is a CROSS-CORE pool.
fn bulk_ep_core(ep string, part PartMap) int {
	return part.core_of[bulk_ep_part(ep, part)] or { 0 }
}

// bulk_cross_core: producer and consumer are on different cores -> the pool must live in the
// shared window (both images address the same bytes), not a per-image global.
fn bulk_cross_core(p BulkPoolCfg, part PartMap) bool {
	return bulk_ep_core(p.producer, part) != bulk_ep_core(p.consumer, part)
}

// bulk_touches: this pool has an endpoint (producer or consumer) on partition `ptn`.
fn bulk_touches(p BulkPoolCfg, part PartMap, ptn string) bool {
	return bulk_ep_part(p.producer, part) == ptn || bulk_ep_part(p.consumer, part) == ptn
}

// emit_bulk_glue generates V declarations and wrapper functions for bulk pools. An INTRA-core
// pool gets a per-image global arena; a CROSS-CORE pool (producer/consumer on different cores)
// is placed at a fixed address in the H755 shared window (duo.h DUO_BULK_ADDR) so both images
// address the SAME pool. Cross-core placement is deterministic (declaration order, 32 B-aligned)
// and static-checked against DUO_BULK_MAX, so the two images agree without exchanging state.
//
// image_part selects WHICH image this is emitting for: '' = the bus OWNER (emits every pool —
// its own intra-core globals and every shared window pool); a satellite partition name = that
// SATELLITE image (emits only the cross-core pools with an endpoint on it, using the SAME
// globally-computed offsets so both images derive an identical pointer).
fn emit_bulk_glue(pools []BulkPoolCfg, part PartMap, image_part string) []string {
	if pools.len == 0 {
		return []string{}
	}
	owner := image_part == ''
	// Lay cross-core pools out in the shared window, in declaration order, 32 B-aligned. This
	// runs over ALL pools regardless of image_part, so the owner and a satellite agree on the
	// offset of every shared pool.
	duo_bulk_max := 0xE000 // keep in sync with boards/h755zi/duo.h DUO_BULK_MAX
	mut xcore_off := map[string]int{}
	mut off := 0
	for p in pools {
		if bulk_cross_core(p, part) {
			xcore_off[p.name] = off
			off += (bulk_bytes(p.nbuf, p.bufsz) + 31) & ~31
		}
	}
	if off > duo_bulk_max {
		panic('loom2v: cross-core [[bulk]] pools need ${off} B of the shared window but ' +
			'DUO_BULK_MAX is ${duo_bulk_max} B (boards/h755zi/duo.h) — shrink a pool (bufsz*nbuf) ' +
			'or raise the window')
	}
	// The owner emits every pool; a satellite emits only the shared pools it is an endpoint of.
	scoped := pools.filter(owner || (bulk_cross_core(it, part) && bulk_touches(it, part, image_part)))
	if scoped.len == 0 {
		return []string{}
	}
	has_shared := scoped.any(it.name in xcore_off)
	mut g := []string{}
	g << ''
	g << '// --- Bulk Transport Pools (docs/bulk-transport.md) ---'
	g << '#include "boards/common/bulk.h"'
	if has_shared {
		g << '#include "duo.h" // DUO_BULK_ADDR: cross-core pools live in the H755 shared window'
	}
	g << ''
	g << 'struct C.bulk_t {}'
	g << 'fn C.bulk_init(b &C.bulk_t, nbuf u32, bufsz u32)'
	g << 'fn C.bulk_valid(b &C.bulk_t) int'
	g << 'fn C.bulk_loan(b &C.bulk_t) int'
	g << 'fn C.bulk_publish(b &C.bulk_t, idx u32, len u32)'
	g << 'fn C.bulk_ready(b &C.bulk_t) u32'
	g << 'fn C.bulk_take(b &C.bulk_t, len &u32) int'
	g << 'fn C.bulk_release(b &C.bulk_t, idx u32)'
	g << 'fn C.bulk_buf(b &C.bulk_t, idx u32) &u8'
	g << 'fn C.bulk_overflows(b &C.bulk_t) u32'
	if has_shared {
		g << 'fn C.duo_bulk_addr() usize // returns DUO_BULK_ADDR (boards/h755zi/duo.h)'
	}
	g << ''

	for p in scoped {
		bytes := bulk_bytes(p.nbuf, p.bufsz)
		cross := p.name in xcore_off
		place := if cross { 'shared window @ DUO_BULK_ADDR+0x${xcore_off[p.name].hex()}' } else { 'local arena' }
		g << '// --- Bulk pool: ${p.name} (${p.nbuf} x ${p.bufsz} B; ${p.producer} -> ${p.consumer}; ${place}) ---'
		if cross {
			// no per-image global — the pool IS the shared window bytes; both images derive
			// the SAME pointer from duo.h. One side (the producer image) calls _init; the
			// other polls _valid() before first use (bulk.h attach handshake).
			g << 'fn bulk_${p.name}_ptr() &C.bulk_t {'
			g << '\treturn &C.bulk_t(voidptr(C.duo_bulk_addr() + usize(${xcore_off[p.name]})))'
			g << '}'
		} else {
			g << '@[aligned: 32]'
			g << '__global ('
			g << '\tg_bulk_${p.name}_arena [${bytes}]u8'
			g << ')'
			g << 'fn bulk_${p.name}_ptr() &C.bulk_t {'
			g << '\treturn &C.bulk_t(&g_bulk_${p.name}_arena[0])'
			g << '}'
		}
		g << ''
		g << 'pub fn bulk_${p.name}_init() {'
		g << '\tC.bulk_init(bulk_${p.name}_ptr(), u32(${p.nbuf}), u32(${p.bufsz}))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_valid() bool {'
		g << '\treturn C.bulk_valid(bulk_${p.name}_ptr()) != 0'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_loan() int {'
		g << '\treturn int(C.bulk_loan(bulk_${p.name}_ptr()))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_publish(idx int, len u32) bool {'
		g << '\tif idx < 0 || idx >= ${p.nbuf} || len > u32(${p.bufsz}) {'
		g << '\t\treturn false'
		g << '\t}'
		g << '\tC.bulk_publish(bulk_${p.name}_ptr(), u32(idx), len)'
		g << '\treturn true'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_ready() u32 {'
		g << '\treturn C.bulk_ready(bulk_${p.name}_ptr())'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_take(len &u32) int {'
		g << '\treturn int(C.bulk_take(bulk_${p.name}_ptr(), len))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_release(idx int) bool {'
		g << '\tif idx < 0 || idx >= ${p.nbuf} {'
		g << '\t\treturn false'
		g << '\t}'
		g << '\tC.bulk_release(bulk_${p.name}_ptr(), u32(idx))'
		g << '\treturn true'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_buf(idx int) &u8 {'
		g << '\tif idx < 0 || idx >= ${p.nbuf} {'
		g << '\t\treturn unsafe { nil }'
		g << '\t}'
		g << '\treturn C.bulk_buf(bulk_${p.name}_ptr(), u32(idx))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_overflows() u32 {'
		g << '\treturn C.bulk_overflows(bulk_${p.name}_ptr())'
		g << '}'
		g << ''
	}
	return g
}
