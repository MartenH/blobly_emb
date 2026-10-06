module main

import toml

// [display]: a local screen on a ThreadX node — one more ThreadX thread that owns the LCD, the touch
// panel and LVGL (boards/<board>/display.c, display.h), created at a priority below every other
// thread of the image, so a heavy redraw is preempted by the comm, FB and network threads alike.
// The node provides the screen (ui_create / ui_update) in the C file `ui` names, relative to the
// node's directory. Which board can drive a display is the board's to say: gen/loom_build.mk
// includes boards/$(BOARD)/display.mk, and a board without one stops the build there by name —
// this generator does not know the part (nothing in ecu.toml names it).
const display_keys = ['ui']

struct DisplayCfg {
	on bool
	ui string // the node's screen, a C file relative to its directory
}

fn parse_display(doc toml.Doc) DisplayCfg {
	d := doc.value_opt('display') or { return DisplayCfg{} }
	dm := d.as_map()
	for k, _ in dm {
		if k !in display_keys {
			panic('loom2v: [display] unknown key "${k}" (allowed: ${display_keys})')
		}
	}
	ui := (dm['ui'] or { panic('loom2v: [display] needs `ui`: the C file with the screen (ui_create, ui_update)') }).string()
	if ui == '' || !ui.ends_with('.c') || ui.contains(' ') {
		panic('loom2v: [display] ui = "${ui}": a C file name relative to the node, without spaces')
	}
	return DisplayCfg{
		on: true
		ui: ui
	}
}

// display_check: the shapes [display] does not support yet, refused by name rather than built
// into an image that misbehaves.
fn display_check(m Model) {
	if !m.display.on {
		return
	}
	if !m.target.threadx {
		panic('loom2v: [display] needs [target] kind = "threadx": the display is a thread of its own')
	}
	if m.trace.on {
		panic('loom2v: [display] with [trace]: the display thread is not in the trace manifest yet ' +
			'(its ids and the thread cap) — enable one or the other')
	}
	if has_satellite(m) {
		panic('loom2v: [display] on a node with a satellite image: not supported yet')
	}
}

// lowest_app_prio: the numerically largest (lowest) priority of this image's application
// threads — the floor every platform thread that must yield to them is placed below.
fn lowest_app_prio(m Model) int {
	mut lowest := 0
	for pname, thrs in m.part.threads_of {
		if m.part.external[pname] {
			continue
		}
		for t in thrs {
			p := m.part.thread_prio[t] or { 10 }
			if p > lowest {
				lowest = p
			}
		}
	}
	return if lowest == 0 { 10 } else { lowest }
}

// display_prio: below every other thread of the image — the application threads and, when the
// node runs DoIP, the network's two threads under them (doip_net_prio).
fn display_prio(m Model) int {
	p := if m.doip.on { doip_net_prio(m) + 2 } else { lowest_app_prio(m) + 1 }
	if p > 31 {
		panic('loom2v: [display]: its thread runs below every other thread, at ${p} — past ThreadX\'s 0..31; ' +
			'give the application threads lower numbers')
	}
	return p
}

fn display_c_decls(m Model) []string {
	if !m.display.on {
		return []string{}
	}
	return ['fn C.display_thread_create(u32)']
}

// display_target_create: in tx_application_define, after every other thread is created.
fn display_target_create(m Model) []string {
	if !m.display.on {
		return []string{}
	}
	return ['\tC.display_thread_create(u32(${display_prio(m)})) // [display]: below every other thread']
}

// display_build_lines: what the image links for its display, for gen/loom_build.mk. Defined on
// every ThreadX image, empty without [display], and every ThreadX Makefile lists both variables
// (pinned by threadx_makefiles_test.v), so adding a display to a node needs no Makefile edit.
fn display_build_lines(m Model) string {
	if !m.target.threadx {
		return ''
	}
	if !m.display.on {
		return 'LOOM_DISPLAY_SRCS :=\nLOOM_DISPLAY_DEFS :=\n'
	}
	return '# [display]: the board\'s display thread, LVGL, and this node\'s screen\n' +
		r'$(if $(wildcard $(REPO)/boards/$(BOARD)/display.mk),,$(error [display]: board $(BOARD) has no display (boards/$(BOARD)/display.mk)))' +
		'\ninclude ' + r'$(REPO)/boards/$(BOARD)/display.mk' + '\n' +
		'LOOM_DISPLAY_SRCS = ' + r'$(DISPLAY_SRCS) ' + m.display.ui + r' $(LVGL_A)' + '\n' +
		'LOOM_DISPLAY_DEFS = ' + r'$(DISPLAY_CFLAGS)' + '\n'
}
