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

// c_definitions: the external (non-static, non-weak) functions a C file DEFINES — a line at
// column 0, past any __attribute__((...)) prefix, that opens a parameter list and is not a
// declaration, a static, a preprocessor line or a comment. A return type on the line above is
// fine: the name is the last word before the parenthesis either way.
fn c_definitions(src string) []string {
	mut out := []string{}
	for raw in src.split_into_lines() {
		mut l := raw
		mut weak := false
		for l.starts_with('__attribute__((') {
			weak = weak || l.all_before('))').contains('weak')
			l = l.all_after('))').trim_left(' ')
		}
		if weak || l == '' || !(l[0].is_letter() || l[0] == `_`) || l.starts_with('static')
			|| l.starts_with('extern') || l.starts_with('typedef') || !l.contains('(')
			|| l.trim_right(' ').ends_with(';') {
			continue
		}
		out << l.all_before('(').trim_space().all_after_last(' ').trim_left('*')
	}
	return out
}

fn glue_src(name string) string {
	return os.read_file(os.join_path(@VMODROOT, 'boards', 'common', name)) or { panic(err) }
}

fn comm_glue_src() string {
	return glue_src('comm_glue.c')
}

// The ONE glue covers every shape the generator emits — one app thread or several, one FDCAN or
// a gateway's several, io points or none — so the question "which glue does this image need" has
// one answer. Both directions: the glue defines every symbol loom2v lists for it, and every
// declaration of that family any emitter can write is on the list (a multi-thread gateway once
// declared load_pub_slot against a glue that had none, #359).
fn test_the_glue_defines_every_symbol_the_generator_declares() {
	defs := c_definitions(comm_glue_src())
	for sym in comm_glue_syms {
		assert sym in defs, 'boards/common/comm_glue.c does not define ${sym}'
	}
	shell_defs := c_definitions(glue_src('shell_glue.c'))
	for sym in shell_glue_syms {
		assert sym in shell_defs, 'boards/common/shell_glue.c does not define ${sym}'
	}
	// the [boot] handoff's board side; boot_handoff_ok is weak (the application overrides it)
	boot_src := glue_src('boot_handoff.c')
	boot_defs := c_definitions(boot_src)
	for sym in boot_glue_syms {
		assert sym in boot_defs || boot_src.contains('__attribute__((weak)) int ${sym}('), 'boards/common/boot_handoff.c does not define ${sym}'
	}
	mut bm := Model{}
	bm.boot.on = true
	bm.isotp_conns = [IsotpConn{}]
	for d in diag_target_c_decls(bm).filter(it.starts_with('fn C.')) {
		name := d['fn C.'.len..].all_before('(')
		if name.starts_with('boot_') {
			assert name in boot_glue_syms, 'diag_target_c_decls declares C.${name}, which boot_glue_syms does not list'
		}
	}
	dir := os.join_path(@VMODROOT, 'tools', 'loom2v')
	mut seen := 0
	for f in os.ls(dir) or { panic(err) } {
		if !f.ends_with('.v') || f.ends_with('_test.v') {
			continue
		}
		src := os.read_file(os.join_path(dir, f)) or { panic(err) }
		// every `fn C.` the source spells, whatever quotes or comment it sits in
		for chunk in src.split('fn C.')[1..] {
			name := chunk.all_before('(')
			if name.starts_with('iocb_') || !(name.starts_with('ioc_')
				|| name.starts_with('load_') || name.starts_with('io_exec')
				|| name.starts_with('comm_')) {
				continue
			}
			seen++
			assert name in comm_glue_syms, '${f} declares C.${name}, which comm_glue_syms does not list'
		}
	}
	assert seen >= comm_glue_syms.len, 'found only ${seen} glue declarations in tools/loom2v — did the emitters move?'
	// the shell's built-ins, as the emitter writes them for a [shell] with no commands of its own
	mut m := Model{}
	m.shell.on = true
	for d in shell_c_decls(m) {
		name := d['fn C.'.len..].all_before('(')
		assert name in shell_glue_syms, 'shell_c_decls declares C.${name}, which shell_glue_syms does not list'
	}
	pool := comm_glue_src().split_into_lines().filter(it.starts_with('#define IOC_POOL_N '))
	assert pool == ['#define IOC_POOL_N ${ioc_pool_n}'], 'comm_glue.c IOC_POOL_N is not loom2v ioc_pool_n (${ioc_pool_n}): ${pool}'
}

// Nothing a ThreadX image links defines what the glue defines: the image links the glue beside
// its own target file, so a second definition is a link failure — or, where a copy drifted, two
// behaviours. (A CM4 satellite links no glue and keeps its own stubs.)
fn test_no_c_file_redefines_the_glue() {
	mut glue := c_definitions(comm_glue_src())
	assert 'FDCAN1_IT0_IRQHandler' in glue && 'comm_wake' in glue
	glue << c_definitions(glue_src('shell_glue.c'))
	glue << c_definitions(glue_src('boot_handoff.c')) // its weak conditions seam is for overriding
	assert 'boot_handoff_request' in glue && 'boot_handoff_ok' !in glue
	mut files := []string{}
	for mk in threadx_makefiles() {
		files << os.walk_ext(os.dir(mk), '.c')
	}
	files << os.walk_ext(os.join_path(@VMODROOT, 'boards'), '.c')
	files << os.walk_ext(os.join_path(@VMODROOT, 'driver'), '.c')
	for f in files {
		if f.ends_with(os.join_path('boards', 'common', 'comm_glue.c'))
			|| f.ends_with(os.join_path('boards', 'common', 'shell_glue.c'))
			|| f.ends_with(os.join_path('boards', 'common', 'boot_handoff.c'))
			|| f.contains('/build/') {
			continue
		}
		src := os.read_file(f) or { panic(err) }
		for d in c_definitions(src) {
			assert d !in glue, '${f} defines ${d}, which a shared glue file already defines'
		}
	}
}

fn test_the_glue_list_follows_the_declarations() {
	comm := r'$(REPO)/boards/common/comm_glue.c'
	shell := r'$(REPO)/boards/common/shell_glue.c'
	assert glue_build_lines([]string{}, false) == 'LOOM_GLUE_SRCS :=\n'
	assert glue_build_lines(['fn C.blob_eth_open(&char, u16) int', 'fn C.iocb_pub(int, voidptr)'],
		false) == 'LOOM_GLUE_SRCS :=\n', 'an eth-only image linked the CAN glue'
	for sym in ['load_pub_slot', 'comm_rx_irq_enable_idx', 'io_exec_add', 'ioc_pool_init'] {
		assert glue_build_lines(['fn C.${sym}(int)'], false) == 'LOOM_GLUE_SRCS = ${comm}\n', sym
	}
	// doip_netx.c wakes the comm thread through comm_wake, which no V declaration names
	assert glue_build_lines([]string{}, true) == 'LOOM_GLUE_SRCS = ${comm}\n'
	assert glue_build_lines(['fn C.comm_rx_wait(u32) u32', 'fn C.shell_ps(&u8, int) int'],
		false) == 'LOOM_GLUE_SRCS = ${comm} ${shell}\n'
	assert glue_build_lines(['fn C.shell_boot(&u8, int) int'], false) == 'LOOM_GLUE_SRCS :=\n', 'a node command is its own target_ext.c'
	// the [boot] handoff's board side
	for sym in boot_glue_syms {
		assert glue_build_lines(['fn C.${sym}()'], false) == 'LOOM_GLUE_SRCS = ' +
			r'$(REPO)/boards/common/boot_handoff.c' + '\n', sym
	}
}

// A node behind its bootloader ([boot]) must not `make flash` its application to 0x08000000, over
// the boot: its Makefile hands `flash` to boot/boot.mk's boot-flash (the boot at its base, the
// factory image at the app slot). The Makefile cannot ask its own ecu.toml, so this asks it for them.
fn test_a_boot_node_flashes_through_its_bootloader() {
	mut seen := 0
	for mk in threadx_makefiles() {
		ecu := os.read_file(os.join_path(os.dir(mk), 'ecu.toml')) or { continue }
		if !ecu.split_into_lines().any(it.trim_space() == '[boot]') {
			continue
		}
		seen++
		src := os.read_file(mk) or { panic(err) }
		assert src.contains('ifeq ($(BOOT_ON),1)\nflash: boot-flash\nelse\n'), '${mk}: a [boot] node whose `flash` writes the app over its bootloader'
	}
	assert seen >= 3, 'found ${seen} [boot] nodes — system_full has three'
}

// The CM4's clock release is a CONSUMED handshake with one statement (boards/h755zi/xcore.h): SRAM4
// survives a reset, so a release left in it would start the satellite's kernel before anybody set
// the clocks — and under a boot manager that stays for programming and changes them. So no file but
// xcore.h touches the cell, every satellite takes it through xcore_clk_take (which consumes it), and
// the boot manager parks the satellite before its first clock change.
fn test_the_satellite_clock_release_is_consumed_and_retracted() {
	mut files := []string{}
	for top in ['examples', 'boards', 'boot'] {
		files << os.walk_ext(os.join_path(@VMODROOT, top), '.c').filter(!it.contains('/build/'))
	}
	mut sats := 0
	for f in files {
		src := os.read_file(f) or { panic(err) }
		assert !src.contains('XCORE_CLK_ADDR'), '${f} touches the clock-release cell itself — go through xcore.h'
		if src.contains('void xcore_wait_clocks(void)') {
			sats++
			assert src.all_after('void xcore_wait_clocks(void)').all_before('}').contains('xcore_clk_take()'), '${f}: the satellite does not consume the release'
		}
	}
	assert sats >= 2, 'found ${sats} satellites'
	xc := os.read_file(os.join_path(@VMODROOT, 'boards', 'h755zi', 'xcore.h')) or { panic(err) }
	take := xc.all_after('static inline void xcore_clk_take(void)').all_before('\n}')
	assert take.contains('*clk = 0u;'), 'xcore_clk_take does not consume'
	boot := os.read_file(os.join_path(@VMODROOT, 'boot', 'target', 'main.v')) or { panic(err) }
	body := boot.all_after('fn main() {')
	park := body.index('C.boot_park_satellite()') or { -1 }
	assert park >= 0, 'the boot never parks the satellite'
	// before the decision, so the jump to the app is covered too, and before any clock change
	assert park < (body.index('boot.decide(') or { -1 }), 'the satellite is parked after the boot decision — a jump to the app skips it'
	assert park < (body.index('C.board_clock_init()') or { -1 }), 'the boot changes the clocks before parking the satellite'
}
