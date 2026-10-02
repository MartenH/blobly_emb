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
