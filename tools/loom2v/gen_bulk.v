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

// emit_bulk_glue generates V declarations and wrapper functions for all bulk pools
fn emit_bulk_glue(pools []BulkPoolCfg) []string {
	if pools.len == 0 {
		return []string{}
	}
	mut g := []string{}
	g << ''
	g << '// --- Bulk Transport Pools (docs/bulk-transport.md) ---'
	g << '#include "boards/common/bulk.h"'
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
	g << ''

	for p in pools {
		// BULK_BYTES(nbuf, bufsz) = 96 + (((3 * 4 * nbuf) + 31) & ~31) + nbuf * bufsz
		bytes := 96 + (((3 * 4 * p.nbuf) + 31) & ~31) + p.nbuf * p.bufsz
		g << '// --- Bulk pool: ${p.name} (${p.nbuf} buffers x ${p.bufsz} bytes) ---'
		g << '__global ('
		g << '\tg_bulk_${p.name}_arena [${bytes}]u8'
		g << ')'
		g << ''
		g << 'pub fn bulk_${p.name}_init() {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\tC.bulk_init(ptr, u32(${p.nbuf}), u32(${p.bufsz}))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_valid() bool {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\treturn C.bulk_valid(ptr) != 0'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_loan() int {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\treturn int(C.bulk_loan(ptr))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_publish(idx int, len u32) {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\tC.bulk_publish(ptr, u32(idx), len)'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_ready() u32 {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\treturn C.bulk_ready(ptr)'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_take(len &u32) int {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\treturn int(C.bulk_take(ptr, len))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_release(idx int) {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\tC.bulk_release(ptr, u32(idx))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_buf(idx int) &u8 {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\treturn C.bulk_buf(ptr, u32(idx))'
		g << '}'
		g << ''
		g << 'pub fn bulk_${p.name}_overflows() u32 {'
		g << '\tptr := &C.bulk_t(&g_bulk_${p.name}_arena[0])'
		g << '\treturn C.bulk_overflows(ptr)'
		g << '}'
		g << ''
	}
	return g
}
