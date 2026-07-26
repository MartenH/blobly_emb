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
// to its owning partition. THREAD-first, matching ecumodel.validate_bulk (`thread_part[ep] or
// {ep}`): if a name were ever both a thread and a partition, both sites must classify it the
// same way, or validation and codegen could disagree on cross- vs intra-core.
fn bulk_ep_part(ep string, part PartMap) string {
	return part.thread_part[ep] or { ep }
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

// bulk_part_local: this partition's code is emitted by the OWNER image — i.e. it is NOT a
// generated satellite (image =) and NOT a hand-written external partition.
fn bulk_part_local(ptn string, part PartMap) bool {
	return ptn !in part.image && !(part.external[ptn] or { false })
}

// bulk_in_image: does the image identified by `image_part` ('' = owner) emit this pool? The
// rule is uniform for intra- and cross-core pools: an image emits a pool iff one of the pool's
// endpoints lives in THAT image. So an intra-core pool sitting inside a satellite partition is
// emitted by the satellite (where its FBs run), NOT dumped into the owner's BSS; and a satellite
// only emits the shared pools it is actually an endpoint of.
fn bulk_in_image(p BulkPoolCfg, part PartMap, image_part string) bool {
	pp := bulk_ep_part(p.producer, part)
	cp := bulk_ep_part(p.consumer, part)
	if image_part != '' {
		return pp == image_part || cp == image_part
	}
	return bulk_part_local(pp, part) || bulk_part_local(cp, part)
}

// bulk_image_role reports whether the image `image_part` ('' = owner) is the PRODUCER and/or the
// CONSUMER end of any CROSS-core pool. A platform service loop on that image polls the pool
// accordingly (docs/bulk-transport.md "service threads for everything else"); the app never
// touches it. Intra-core pools terminate within one image and need no cross-core service.
fn bulk_image_role(bulk []BulkPoolCfg, part PartMap, image_part string) (bool, bool) {
	mut produces := false
	mut consumes := false
	for p in bulk {
		if !bulk_cross_core(p, part) {
			continue
		}
		pp := bulk_ep_part(p.producer, part)
		cp := bulk_ep_part(p.consumer, part)
		here := fn (ptn string, part PartMap, image_part string) bool {
			return if image_part == '' { bulk_part_local(ptn, part) } else { ptn == image_part }
		}
		if here(pp, part, image_part) {
			produces = true
		}
		if here(cp, part, image_part) {
			consumes = true
		}
	}
	return produces, consumes
}

// emit_bulk_service_decls externs the platform bulk-service seams this image needs. The glue C
// (the same TU that provides xcore_bulk_base) implements them: the producer service loans a buffer,
// fills it, and publishes; the consumer service polls valid/take, uses the buffer, and releases.
// The app never sees the pool — this is the "platform module terminates bulk" rule (isolation
// note in docs/bulk-transport.md) until an osal.bulk transport exists.
fn emit_bulk_service_decls(bulk []BulkPoolCfg, part PartMap, image_part string) []string {
	produces, consumes := bulk_image_role(bulk, part, image_part)
	mut out := []string{}
	if produces {
		out << 'fn C.xcore_bulk_produce() // platform producer service (glue): loan+fill+publish'
	}
	if consumes {
		out << 'fn C.xcore_bulk_consume() // platform consumer service (glue): poll+take+release'
	}
	return out
}

// emit_bulk_service_arm emits the per-loop service poll(s) for this image, `indent`-prefixed.
// First cut is a POLL each service pass; the HSEM doorbell (block until the producer rings) is a
// later rung (docs/bulk-transport.md).
fn emit_bulk_service_arm(bulk []BulkPoolCfg, part PartMap, image_part string, indent string) []string {
	produces, consumes := bulk_image_role(bulk, part, image_part)
	mut out := []string{}
	if produces {
		out << '${indent}C.xcore_bulk_produce() // cross-core bulk producer (platform-owned pool)'
	}
	if consumes {
		out << '${indent}C.xcore_bulk_consume() // cross-core bulk consumer (platform-owned pool)'
	}
	return out
}

// emit_bulk_glue generates V declarations and wrapper functions for bulk pools. An INTRA-core
// pool gets a per-image global arena; a CROSS-CORE pool (producer/consumer on different cores)
// is placed at a fixed address in the H755 shared window (xcore.h XCORE_BULK_ADDR) so both images
// address the SAME pool. Cross-core placement is deterministic (declaration order, 32 B-aligned)
// and static-checked against XCORE_BULK_MAX, so the two images agree without exchanging state.
//
// image_part selects WHICH image this is emitting for: '' = the bus OWNER (emits pools whose
// endpoints are its local partitions — intra-core globals for them plus the shared window pools
// it is an endpoint of); a satellite partition name = that SATELLITE image (emits the pools it
// is an endpoint of, using the SAME globally-computed offsets so both images derive an identical
// pointer for any shared pool).
fn emit_bulk_glue(pools []BulkPoolCfg, part PartMap, image_part string) []string {
	if pools.len == 0 {
		return []string{}
	}
	// Lay cross-core pools out in the shared window, in declaration order, 32 B-aligned. This
	// runs over ALL pools regardless of image_part, so the owner and a satellite agree on the
	// offset of every shared pool.
	xcore_bulk_max := 0xE000 // keep in sync with boards/h755zi/xcore.h XCORE_BULK_MAX
	mut xcore_off := map[string]int{}
	mut off := 0
	for p in pools {
		if bulk_cross_core(p, part) {
			xcore_off[p.name] = off
			off += (bulk_bytes(p.nbuf, p.bufsz) + 31) & ~31
		}
	}
	if off > xcore_bulk_max {
		panic('loom2v: cross-core [[bulk]] pools need ${off} B of the shared window but ' +
			'XCORE_BULK_MAX is ${xcore_bulk_max} B (boards/h755zi/xcore.h) — shrink a pool (bufsz*nbuf) ' +
			'or raise the window')
	}
	// Each image emits the pools it owns an endpoint of (owner = its local partitions; a
	// satellite = itself). This keeps an intra-core satellite-local pool in the satellite.
	scoped := pools.filter(bulk_in_image(it, part, image_part))
	if scoped.len == 0 {
		return []string{}
	}
	has_shared := scoped.any(it.name in xcore_off)
	mut g := []string{}
	g << ''
	g << '// --- Bulk Transport Pools (docs/bulk-transport.md) ---'
	// boards/common is on the target C path via BOARD_INCS, but a HOST/sim build compiles from
	// the repo root without it — so anchor the include at the v.mod root (@VMODROOT), which
	// resolves from either cwd.
	g << '#flag -I @VMODROOT/boards/common'
	g << '#include "bulk.h"'
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
		// The cross-core region base comes from a PLATFORM seam, exactly like xcore_pub/xcore_ioc_init:
		// generated code externs it and the board's glue C provides it (from xcore.h's XCORE_BULK_ADDR
		// on the H755). Generated code never includes a board header — it stays board-agnostic.
		g << 'fn C.xcore_bulk_base() usize // cross-core bulk region base (board glue; H755 = XCORE_BULK_ADDR)'
	}
	g << ''

	for p in scoped {
		bytes := bulk_bytes(p.nbuf, p.bufsz)
		cross := p.name in xcore_off
		place := if cross { 'shared window @ base+0x${xcore_off[p.name].hex()}' } else { 'local arena' }
		g << '// --- Bulk pool: ${p.name} (${p.nbuf} x ${p.bufsz} B; ${p.producer} -> ${p.consumer}; ${place}) ---'
		if cross {
			// no per-image global — the pool IS the shared window bytes; both images derive the
			// SAME pointer from the platform base. One side (the producer image) calls _init; the
			// other polls _valid() before first use (bulk.h attach handshake).
			g << 'fn bulk_${p.name}_ptr() &C.bulk_t {'
			g << '\treturn &C.bulk_t(voidptr(C.xcore_bulk_base() + usize(${xcore_off[p.name]})))'
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
		// Capability split: emit only the ROLE-appropriate wrappers for this image. The producer
		// owns bring-up + the free/publish side (init/loan/publish/overflows); the consumer owns
		// the take/release side (valid/ready/take/release). Calling the wrong side from the wrong
		// image would corrupt the other side's ring cursors — so for a CROSS-core pool the wrong
		// half simply doesn't exist here. An INTRA-core pool has both ends in one image, so it
		// emits the full API. `buf` is shared (producer fills, consumer reads).
		pp := bulk_ep_part(p.producer, part)
		cp := bulk_ep_part(p.consumer, part)
		prod_here := if image_part == '' { bulk_part_local(pp, part) } else { pp == image_part }
		cons_here := if image_part == '' { bulk_part_local(cp, part) } else { cp == image_part }
		if prod_here {
			g << 'pub fn bulk_${p.name}_init() {'
			g << '\tC.bulk_init(bulk_${p.name}_ptr(), u32(${p.nbuf}), u32(${p.bufsz}))'
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
			g << 'pub fn bulk_${p.name}_overflows() u32 {'
			g << '\treturn C.bulk_overflows(bulk_${p.name}_ptr())'
			g << '}'
			g << ''
		}
		if cons_here {
			g << 'pub fn bulk_${p.name}_valid() bool {'
			g << '\treturn C.bulk_valid(bulk_${p.name}_ptr()) != 0'
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
		}
		g << 'pub fn bulk_${p.name}_buf(idx int) &u8 {'
		g << '\tif idx < 0 || idx >= ${p.nbuf} {'
		g << '\t\treturn unsafe { nil }'
		g << '\t}'
		g << '\treturn C.bulk_buf(bulk_${p.name}_ptr(), u32(idx))'
		g << '}'
		g << ''
	}
	return g
}
