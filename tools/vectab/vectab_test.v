module main

import os

// Every vector table an image links covers EVERY interrupt its part defines, each handler at
// its IRQn + 16, checked against the part's CMSIS device header rather than against a comment
// in the table. The gap this pins (#360): the shared table stopped at IRQ149, the H72x/H73x run
// to IRQ162, so FDCAN3's handler was referenced by nothing, --gc-sections deleted it, and the
// first frame on a third bus would have made the core fetch a vector past the end of the table.

const repo = @VMODROOT
const cmsis = os.join_path(repo, 'third_party', 'cmsis_device_h7', 'Include')
// the default handler of each kind of table: every slot not named for its interrupt holds it
const asm_default = '__tx_BadHandler'
const table_markers = ['.section .vectors', 'section(".isr_vector")']

// device_irqs: the part's peripheral interrupts (IRQn >= 0) by number, read from the IRQn_Type
// enum of its CMSIS device header. `part` is the define a board passes, e.g. STM32H735xx.
fn device_irqs(part string) map[int]string {
	hdr := os.join_path(cmsis, part.to_lower() + '.h')
	src := os.read_file(hdr) or {
		panic('${hdr}: ${err} — the CMSIS device headers are a dependency of this test: run `make deps-cmsis`')
	}
	end := src.index('} IRQn_Type;') or { panic('${hdr}: no IRQn_Type enum') }
	body := src[..end].all_after_last('typedef enum')
	mut out := map[int]string{}
	for raw in body.split_into_lines() {
		l := raw.all_before('/*').all_before('//').trim_space()
		// a conditional enum would make the numbering depend on defines this parser ignores
		assert !l.starts_with('#'), '${hdr}: a preprocessor line inside IRQn_Type: ${l}'
		if !l.contains('=') {
			continue
		}
		name := l.all_before('=').trim_space()
		n := l.all_after('=').all_before(',').trim_space().int()
		assert name.ends_with('_IRQn'), '${hdr}: unexpected enumerator ${name}'
		if n >= 0 {
			assert n !in out, '${hdr}: IRQ${n} defined twice (${out[n]}, ${name})'
			out[n] = name
		}
	}
	assert out.len > 100, '${hdr}: read only ${out.len} interrupts'
	return out
}

fn max_irq(irqs map[int]string) int {
	mut m := -1
	for n, _ in irqs {
		if n > m {
			m = n
		}
	}
	return m
}

// handler_of: the handler a CMSIS interrupt name is served by (FDCAN3_IT0_IRQn ->
// FDCAN3_IT0_IRQHandler), the naming ST's own startup files use
fn handler_of(irqn string) string {
	return irqn.trim_string_right('IRQn') + 'IRQHandler'
}

// asm_table: the .word entries of a vectors file's `_vectors:` table, in order. Anything but a
// .word between the label and the next section is refused, so a .rept or an #if cannot make
// the count this reads differ from the count the assembler emits.
fn asm_table(path string) []string {
	mut src := os.read_file(path) or { panic(err) }
	for src.contains('/*') {
		src = src.all_before('/*') + src.all_after('/*').all_after('*/')
	}
	mut out := []string{}
	mut inside := false
	for raw in src.split_into_lines() {
		l := raw.all_before('//').trim_space()
		if l == '_vectors:' {
			inside = true
			continue
		}
		if !inside || l == '' {
			continue
		}
		if l.starts_with('.section') {
			break
		}
		assert l.starts_with('.word '), '${path}: `${l}` inside the vector table — only .word entries are read'
		out << l.all_after('.word ').trim_space()
	}
	assert out.len > 16, '${path}: no _vectors table read'
	return out
}

// c_irq_lines: the part -> VECTOR_IRQS chain of the bare-metal startup.c
fn c_irq_lines(path string) map[string]int {
	src := os.read_file(path) or { panic(err) }
	mut out := map[string]int{}
	mut parts := []string{}
	for raw in src.split_into_lines() {
		l := raw.trim_space()
		if l.starts_with('#if ') || l.starts_with('#elif ') {
			parts = l.split('defined(').filter(it.starts_with('STM32')).map(it.all_before(')'))
		} else if l.starts_with('#define VECTOR_IRQS ') {
			for p in parts {
				out[p] = l.all_after('#define VECTOR_IRQS ').trim_space().int()
			}
			parts = []
		}
	}
	return out
}

// mk_vars: a board.mk's variables, continuation lines joined
fn mk_vars(path string) map[string]string {
	src := os.read_file(path) or { panic(err) }.replace('\\\n', ' ')
	mut out := map[string]string{}
	for l in src.split_into_lines() {
		if l.starts_with('#') || !l.contains('=') {
			continue
		}
		name := l.all_before('=').trim_right(':').trim_space()
		if name.contains(' ') || name.contains('$') {
			continue
		}
		out[name] = l.all_after('=').trim_space()
	}
	return out
}

fn has_table(path string) bool {
	src := os.read_file(path) or { return false }
	return table_markers.any(src.contains(it))
}

struct Use {
	board string
	list  string // the board.mk BSP variable that links the table
	table string // repo-relative
	part  string
}

// table_uses: every (vector table, part) an image can link — each board's BSP lists, each list
// with the part its own defines name (the CM4 lists with the CM4's)
fn table_uses() []Use {
	mut out := []Use{}
	mut boards := os.ls(os.join_path(repo, 'boards')) or { panic(err) }
	boards.sort()
	for b in boards {
		mk := os.join_path(repo, 'boards', b, 'board.mk')
		if !os.is_file(mk) {
			continue
		}
		vars := mk_vars(mk)
		for list, defs in {
			'BOARD_BSP_THREADX':     'BOARD_DEFS'
			'BOARD_BSP_BARE':        'BOARD_DEFS'
			'BOARD_BSP_CM4_THREADX': 'BOARD_DEFS_CM4'
			'BOARD_BSP_CM4_BARE':    'BOARD_DEFS_CM4'
		} {
			files := vars[list] or { continue }
			parts := (vars[defs] or { '' }).fields().filter(it.starts_with('-DSTM32H')).map(it[2..])
			assert parts.len == 1, '${mk}: ${defs} names ${parts.len} STM32 parts'
			tables := files.fields().map(it.replace('$(BOARD_COMMON)', 'boards/common').replace('$(BOARD_DIR)',
				'boards/${b}')).filter(has_table(os.join_path(repo, it)))
			assert tables.len == 1, '${mk}: ${list} links ${tables.len} vector tables: ${tables}'
			out << Use{b, list, tables[0], parts[0]}
		}
	}
	assert out.len >= 8, 'found only ${out.len} board vector tables'
	return out
}

// code_handlers: every *_IRQHandler a C file under boards/ or examples/ defines
fn code_handlers() map[string]string {
	mut out := map[string]string{}
	for top in ['boards', 'examples'] {
		for f in os.walk_ext(os.join_path(repo, top), '.c') {
			if f.contains('/build/') {
				continue
			}
			for raw in (os.read_file(f) or { panic(err) }).split_into_lines() {
				l := raw.all_after('))').trim_space()
				if l.starts_with('void ') && l.contains('_IRQHandler(void)') {
					out[l.all_after('void ').all_before('(').trim_space()] = f.all_after(repo + '/')
				}
			}
		}
	}
	assert 'FDCAN1_IT0_IRQHandler' in out && 'FDCAN3_IT0_IRQHandler' in out, 'handler scan found ${out.keys()}'
	return out
}

fn test_every_vector_table_covers_its_part() {
	handlers := code_handlers()
	mut all_irqns := map[string]bool{}
	for u in table_uses() {
		irqs := device_irqs(u.part)
		for _, name in irqs {
			all_irqns[name] = true
		}
		top := max_irq(irqs)
		at := '${u.table} (${u.board} ${u.list}, ${u.part})'
		path := os.join_path(repo, u.table)
		if u.table.ends_with('.S') {
			t := asm_table(path)
			assert t.len == 16 + top + 1, '${at}: ${t.len - 16} interrupt slots, the part defines IRQ0..IRQ${top}'
			for n in 0 .. top + 1 {
				e := t[16 + n]
				if e == asm_default {
					continue
				}
				name := irqs[n] or { '' }
				assert name != '', '${at}: IRQ${n} holds ${e}, the part defines no interrupt there'
				assert e == handler_of(name), '${at}: IRQ${n} (${name}) holds ${e}'
			}
			// every handler the code defines is reachable on each part that has its interrupt
			for h, file in handlers {
				for n, name in irqs {
					if handler_of(name) == h {
						assert t[16 + n] == h, '${at}: ${h} (${file}) is not at IRQ${n} — unreferenced, --gc-sections deletes it'
					}
				}
			}
			if 'FDCAN3_IT0_IRQn' !in irqs.values() {
				assert !t.any(it.contains('FDCAN3')), '${at}: names FDCAN3, which the part does not have'
			}
		} else {
			// the bare-metal table: polled images, every interrupt slot the default handler
			lines := c_irq_lines(path)
			assert u.part in lines, '${at}: no VECTOR_IRQS for ${u.part}'
			assert lines[u.part] == top + 1, '${at}: VECTOR_IRQS ${lines[u.part]}, the part defines IRQ0..IRQ${top}'
		}
	}
	for h, file in handlers {
		assert h.trim_string_right('IRQHandler') + 'IRQn' in all_irqns, '${file}: ${h} names no interrupt of any built part'
	}
}

// the bare-metal table states a count for every part it lists, and each count is that part's
fn test_the_bare_table_counts_match_their_headers() {
	path := os.join_path(repo, 'boards', 'common', 'startup.c')
	src := os.read_file(path) or { panic(err) }
	assert src.contains('g_pfnVectors[16 + VECTOR_IRQS]')
	assert src.contains('[16 ... 16 + VECTOR_IRQS - 1] = Default_Handler')
	lines := c_irq_lines(path)
	assert lines.len >= 3, '${lines}'
	for part, n in lines {
		assert n == max_irq(device_irqs(part)) + 1, '${path}: VECTOR_IRQS ${n} for ${part}'
	}
}

// VTOR ignores the low bits of the table address up to the table's size rounded to a power of
// two: a boot-chain app's table at APP_VECTORS must sit on that boundary, or the core indexes
// the wrong words. The H72x table is 179 words -> 1 KiB alignment.
fn test_app_vectors_fit_the_vtor_alignment() {
	for u in table_uses().filter(it.list == 'BOARD_BSP_THREADX') {
		bm := os.join_path(repo, 'boards', u.board, 'bootmap.h')
		if !os.is_file(bm) {
			continue
		}
		src := os.read_file(bm) or { panic(err) }
		mut base := u64(0)
		mut off := u64(0)
		for l in src.split_into_lines() {
			if l.starts_with('#define APP_BASE ') {
				base = l.fields()[2].trim_right('u').u64()
			} else if l.starts_with('#define APP_VECTORS ') {
				off = l.all_after('+').all_before(')').trim_space().trim_right('u').u64()
			}
		}
		assert base > 0 && off > 0, '${bm}: APP_BASE/APP_VECTORS not read'
		bytes := u64(asm_table(os.join_path(repo, u.table)).len * 4)
		mut align := u64(1)
		for align < bytes {
			align <<= 1
		}
		assert (base + off) % align == 0, '${bm}: APP_VECTORS 0x${(base + off).hex()} is not ${align}-byte aligned for ${u.table}'
	}
}

// every vector table in the tree is one a board.mk links, so none escapes the checks above
fn test_no_vector_table_outside_the_boards() {
	known := table_uses().map(it.table)
	for top in ['boards', 'examples'] {
		for ext in ['.c', '.S', '.s'] {
			for f in os.walk_ext(os.join_path(repo, top), ext) {
				rel := f.all_after(repo + '/')
				if rel.contains('/build/') || !has_table(f) {
					continue
				}
				assert rel in known, '${rel}: a vector table no board.mk links — this test cannot check it'
			}
		}
	}
}
