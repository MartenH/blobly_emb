module main

import os

// Every ThreadX image links what its generation asks for. loom2v writes the image's source lists
// into gen/loom_build.mk (LOOM_FAULT_SRCS always, empty when unused; LOOM_NET_SRCS where a network
// is configured), so a feature added to a node's ecu.toml — a [[fault]] — needs no Makefile edit.
// That holds only if every ThreadX Makefile includes the file, remakes it (or a first build reads
// it before generation wrote it, and links nothing), and lists the variable in what it links.
// The gap this pins: faults wired into one node's Makefile by hand, and every other ThreadX image
// failing to link iocb_* the day it declared one (codex on #350).

fn threadx_makefiles() []string {
	mut out := []string{}
	ex := os.join_path(@VMODROOT, 'examples')
	mut dirs := os.ls(ex) or { panic(err) }
	dirs.sort()
	for d in dirs {
		out << os.join_path(ex, d, 'Makefile')
		nodes := os.join_path(ex, d, 'nodes')
		if os.is_dir(nodes) {
			mut ns := os.ls(nodes) or { panic(err) }
			ns.sort()
			for n in ns {
				out << os.join_path(nodes, n, 'Makefile')
			}
		}
	}
	return out.filter(os.is_file(it) && (os.read_file(it) or { '' }).contains('BOARD_BSP_THREADX'))
}

// bsp_definition: the BSP variable's definition, continuation lines joined
fn bsp_definition(src string) string {
	lines := src.split_into_lines()
	for i, l in lines {
		if !l.starts_with('BSP') {
			continue
		}
		mut def := l
		mut j := i
		for lines[j].trim_right(' ').ends_with('\\') && j + 1 < lines.len {
			j++
			def += ' ' + lines[j]
		}
		return def
	}
	return ''
}

fn test_every_threadx_makefile_links_the_generated_sources() {
	mks := threadx_makefiles()
	assert mks.len >= 10, 'found only ${mks.len} ThreadX Makefiles: ${mks}'
	for mk in mks {
		src := os.read_file(mk) or { panic(err) }
		inc := src.index('\n-include gen/loom_build.mk') or {
			assert false, '${mk}: does not include gen/loom_build.mk'
			continue
		}
		assert src.contains('\ngen/loom_build.mk:'), '${mk}: no remake rule for gen/loom_build.mk — a first build reads it before generation writes it'
		// ...and not for `make clean`, which would regenerate everything just to delete it
		assert src.contains('ifneq (\$(MAKECMDGOALS),clean)\n-include gen/loom_build.mk'), '${mk}: the include is not skipped for clean'
		bsp := bsp_definition(src)
		assert bsp.contains('$(LOOM_FAULT_SRCS)'), '${mk}: BSP does not list $(LOOM_FAULT_SRCS)'
		assert bsp.contains('$(LOOM_GLUE_SRCS)'), '${mk}: BSP does not list $(LOOM_GLUE_SRCS)'
		// a prerequisite list is expanded where the rule is read: the include must come first
		elf := src.index('.elf: ') or {
			assert false, '${mk}: no .elf rule'
			continue
		}
		assert inc < elf, '${mk}: gen/loom_build.mk is included after the link rule reads $(BSP)'
		// iocb.c reaches an image through ONE list: the network's, or the fault cells'
		hand := src.split_into_lines().filter(!it.trim_space().starts_with('#')
			&& it.contains('boards/common/iocb.c'))
		assert hand.len == 0, '${mk}: names iocb.c by hand: ${hand}'
		// the generic glue reaches an image through LOOM_GLUE_SRCS alone (#359): a Makefile
		// that picks a glue file picks wrong for some shape (a multi-thread gateway linked neither)
		glue := src.split_into_lines().filter(!it.trim_space().starts_with('#')
			&& (it.contains('comm_glue.c') || it.contains('io_glue.c')))
		assert glue.len == 0, '${mk}: names a glue file by hand: ${glue}'
	}
}

// the eth thread's network list carries iocb.c, so the fault list must stay empty there
fn test_the_byte_ioc_is_linked_once() {
	mut m := Model{}
	m.target.threadx = true
	assert fault_build_lines(m) == 'LOOM_FAULT_SRCS :=\n', 'a ThreadX image without faults leaves the variable undefined'
	m.faults = [FaultCfg{
		name: 'A'
		fb:   'Mon'
	}]
	assert fault_build_lines(m).contains('boards/common/iocb.c')
	m.eth_frames = [EthFrame{
		name: 'Ev'
	}]
	assert fault_build_lines(m) == 'LOOM_FAULT_SRCS :=\n', 'iocb.c listed beside the network list that already carries it'
	m.target.threadx = false
	assert fault_build_lines(m) == '', 'a host image wrote a ThreadX source list'
}

// c_definitions: the external (non-static) functions a C file DEFINES — a line at column 0 that
// opens a parameter list and is not a declaration, a static, a preprocessor line or a comment
fn c_definitions(src string) []string {
	mut out := []string{}
	for l in src.split_into_lines() {
		if l == '' || !(l[0].is_letter() || l[0] == `_`) || l.starts_with('static')
			|| l.starts_with('extern') || l.starts_with('__attribute__((weak))')
			|| !l.contains('(') || l.trim_right(' ').ends_with(';') {
			continue
		}
		head := l.all_before('(').trim_space()
		out << head.all_after_last(' ').trim_left('*')
	}
	return out
}

fn comm_glue_src() string {
	return os.read_file(os.join_path(@VMODROOT, 'boards', 'common', 'comm_glue.c')) or { panic(err) }
}

// The ONE glue covers every shape the generator emits — one app thread or several, one FDCAN or
// a gateway's three, io points or none — so the question "which glue does this image need" has
// one answer. Both directions: the glue defines every symbol loom2v lists for it, and every
// declaration of that family any emitter can write is on the list (a multi-thread gateway once
// declared load_pub_slot against a glue that had none, #359).
fn test_the_glue_defines_every_symbol_the_generator_declares() {
	defs := c_definitions(comm_glue_src())
	for sym in comm_glue_syms {
		assert sym in defs, 'boards/common/comm_glue.c does not define ${sym}'
	}
	dir := os.join_path(@VMODROOT, 'tools', 'loom2v')
	for f in os.ls(dir) or { panic(err) } {
		if !f.ends_with('.v') || f.ends_with('_test.v') {
			continue
		}
		src := os.read_file(os.join_path(dir, f)) or { panic(err) }
		for chunk in src.split("'fn C.")[1..] {
			name := chunk.all_before('(')
			if name.starts_with('iocb_') || !(name.starts_with('ioc_')
				|| name.starts_with('load_') || name.starts_with('io_exec')
				|| name.starts_with('comm_')) {
				continue
			}
			assert name in comm_glue_syms, '${f} declares C.${name}, which comm_glue_syms does not list'
		}
	}
	pool := comm_glue_src().split_into_lines().filter(it.starts_with('#define IOC_POOL_N '))
	assert pool == ['#define IOC_POOL_N ${ioc_pool_n}'], 'comm_glue.c IOC_POOL_N is not loom2v ioc_pool_n (${ioc_pool_n}): ${pool}'
}

// Nothing a ThreadX image links defines what the glue defines: the image links the glue beside
// its own target file, so a second definition is a link failure — or, where a copy drifted, two
// behaviours. (A CM4 satellite links no glue and keeps its own stubs.)
fn test_no_c_file_redefines_the_glue() {
	glue := c_definitions(comm_glue_src())
	assert 'FDCAN1_IT0_IRQHandler' in glue && 'comm_wake' in glue
	mut files := []string{}
	for mk in threadx_makefiles() {
		files << os.walk_ext(os.dir(mk), '.c')
	}
	files << os.walk_ext(os.join_path(@VMODROOT, 'boards'), '.c')
	files << os.walk_ext(os.join_path(@VMODROOT, 'driver'), '.c')
	for f in files {
		if f.ends_with(os.join_path('boards', 'common', 'comm_glue.c')) || f.contains('/build/') {
			continue
		}
		src := os.read_file(f) or { panic(err) }
		for d in c_definitions(src) {
			assert d !in glue, '${f} defines ${d}, which boards/common/comm_glue.c already defines'
		}
	}
}

fn test_the_glue_list_follows_the_declarations() {
	assert glue_build_lines([]string{}) == 'LOOM_GLUE_SRCS :=\n'
	assert glue_build_lines(['fn C.blob_eth_open(&char, u16) int', 'fn C.iocb_pub(int, voidptr)']) == 'LOOM_GLUE_SRCS :=\n', 'an eth-only image linked the CAN glue'
	for sym in ['load_pub_slot', 'comm_rx_irq_enable_idx', 'io_exec_add', 'ioc_pool_init'] {
		assert glue_build_lines(['fn C.${sym}(int)']).contains('boards/common/comm_glue.c'), sym
	}
}
