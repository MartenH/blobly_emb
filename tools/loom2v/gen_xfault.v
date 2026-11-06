// loom2v's faults owned by an FB on a satellite core (REQ-PLACE-008, docs/fb-placement.md).
//
// On the owner a fault-owning FB has two byte-IOC cells with the comm thread: its debounced
// reports up, the clear generations and held flags down (docs/diagnostics.md §3.3). An FB on a
// generated satellite keeps the same debounce on its own thread and the same two exchanges, each
// carried by a cross-core channel instead: the reports on a wide up channel the comm thread polls
// behind the layout gate, the control on an owner-written down channel the FB's thread reads. The
// fault memory, 0x19 / 0x14 / 0x85 and the operation cycle stay where they are.
//
// The lanes are packed field by field, never the structs' bytes, so the two images agree on the
// encoding and not on a struct layout: per fault two report lanes (gen | failed << 16, fails |
// tests << 16) and one control lane (gen | held << 16) — eight faults, the per-producer limit,
// fill one 64 B channel.
module main

import comm.fault

// fault_on_sat: fault-owning `fb` runs on a generated satellite image
fn fault_on_sat(m Model, fb string) bool {
	p := m.part.thread_part[m.part.fb_thread[fb] or { '' }] or { '' }
	return (m.part.image[p] or { '' }) != ''
}

// fault_local_fbs: the fault-owning FBs on this image — the ones with byte-IOC cells
fn fault_local_fbs(m Model) []string {
	return fault_fbs(m).filter(!fault_on_sat(m, it))
}

// fault_sat_fbs: the fault-owning FBs of satellite partition `part`
fn fault_sat_fbs(m Model, part string) []string {
	return fault_fbs(m).filter(fault_on_sat(m, it)
		&& (m.part.thread_part[m.part.fb_thread[it] or { '' }] or { '' }) == part)
}

// fault_count: the faults `fb`'s thread debounces — the entries its reports carry
fn fault_count(m Model, fb string) int {
	return m.faults.filter(it.fb == fb && it.signal == '').len
}

fn fault_rep_lanes(m Model, fb string) int {
	return 2 * fault_count(m, fb)
}

fn fault_ctl_lanes(m Model, fb string) int {
	return fault_count(m, fb)
}

// fault_xcore_derive lays out each satellite fault-owning FB's two channels after the signals'. Its
// partition publishes the layout acknowledgement too, so it counts toward the one satellite producer
// the handshake carries (build_model's guard counts the signals' producers).
fn fault_xcore_derive(mut m Model) {
	mut producers := []string{}
	for sname in m.xcore_names {
		p := ep_part(m.part, (m.sig_of[sname] or { SigInfo{} }).from)
		if p !in producers {
			producers << p
		}
	}
	for fb in fault_fbs(m) {
		p := m.part.thread_part[m.part.fb_thread[fb] or { '' }] or { '' }
		if fault_on_sat(m, fb) && p !in producers {
			producers << p
		}
	}
	if producers.len > 1 {
		producers.sort()
		panic('loom2v: ${producers.len} satellite partitions publish to the owner (${producers.join(', ')}) ' +
			'— remote signals or a fault\'s reports; the cross-core layout handshake carries ONE satellite today')
	}
	for fb in fault_fbs(m) {
		if !fault_on_sat(m, fb) {
			continue
		}
		n := fault_count(m, fb)
		if n < 1 || n > fault.max_per_producer {
			continue // validate_faults refuses it
		}
		m.fault_xup_off[fb] = m.xcore_xw_total
		m.xcore_xw_total += xioc_n_bytes(2 * n)
		m.fault_xdn_off[fb] = m.xdown_total
		m.xdown_total += xioc_n_bytes(n)
	}
}

// fault_macro: the header name of `fb`'s fault channel — a double underscore no signal's snake
// form can spell
fn fault_macro(fb string) string {
	return '${snake(fb).to_upper()}__FAULTS'
}

// fault_xw_gen_h / fault_ow_gen_h: the channels' part of gen/xcore_gen.h
fn fault_xw_gen_h(m Model) []string {
	mut g := []string{}
	for fb in fault_fbs(m) {
		if off := m.fault_xup_off[fb] {
			g << '#define XCORE_XW_${fault_macro(fb)}_OFF ${off}u // ${fb}\'s fault reports'
			g << '#define XCORE_XW_${fault_macro(fb)}_WORDS ${fault_rep_lanes(m, fb)}u'
		}
	}
	return g
}

fn fault_ow_gen_h(m Model) []string {
	mut g := []string{}
	for fb in fault_fbs(m) {
		if off := m.fault_xdn_off[fb] {
			g << '#define XCORE_OW_${fault_macro(fb)}_OFF ${off}u // ${fb}\'s fault control'
			g << '#define XCORE_OW_${fault_macro(fb)}_WORDS ${fault_ctl_lanes(m, fb)}u'
		}
	}
	return g
}

// fault_layout_desc: the channels' part of the layout-id string (`f:` up, `fo:` down)
fn fault_layout_desc(m Model) string {
	mut desc := ''
	for fb in fault_fbs(m) {
		if off := m.fault_xup_off[fb] {
			desc += 'f:${fb}:xw+${off}:${fault_rep_lanes(m, fb)}|'
			desc += 'fo:${fb}:ow+${m.fault_xdn_off[fb] or { 0 }}:${fault_ctl_lanes(m, fb)}|'
		}
	}
	return desc
}

// fault_sat_take_lines: the comm thread's read of `fb`'s reports — the newest the satellite
// published, behind the layout gate; the last ones while nothing newer came (zero until the first,
// as an owner FB's cell reads)
fn fault_sat_take_lines(m Model, fb string, ind string) []string {
	f := snake(fb)
	r := 'g_frx_${f}'
	mut g := ['${ind}if C.xcore_layout_ok() != 0 && C.xcore_poll_n(u32(${m.fault_xup_off[fb] or { 0 }}), ${fault_rep_lanes(m, fb)}, &${r}[0], &${r}[1]) != 0 { // ${fb}\'s debounced reports, from the satellite']
	for k in 0 .. fault_count(m, fb) {
		a := '${r}[${1 + 2 * k}]'
		b := '${r}[${2 + 2 * k}]'
		g << '${ind}\tg_frep_${f}.r[${k}] = fault.Report{'
		g << '${ind}\t\tgen:    u16(${a})'
		g << '${ind}\t\tfailed: ${a} & 0x1_0000 != 0'
		g << '${ind}\t\tfails:  u16(${b})'
		g << '${ind}\t\ttests:  u16(${b} >> 16)'
		g << '${ind}\t}'
	}
	g << '${ind}}'
	return g
}

// fault_sat_give_lines: the comm thread's publish of `fb`'s control down to the satellite
fn fault_sat_give_lines(m Model, fb string, ind string) []string {
	f := snake(fb)
	mut g := []string{}
	for k in 0 .. fault_count(m, fb) {
		g << '${ind}g_fxl_${f}[${k}] = u32(g_fctl_${f}.gen[${k}]) | if g_fctl_${f}.held[${k}] { u32(0x1_0000) } else { u32(0) }'
	}
	g << '${ind}C.xcore_opub_n(u32(${m.fault_xdn_off[fb] or { 0 }}), &g_fxl_${f}[0]) // ${fb}\'s control -> the satellite'
	return g
}

// fault_sat_control_lines: the satellite FB thread's read of its control — the generations to
// apply and the held flags: zero until the owner's first publish, as a cell reads, then the last
// one while none newer is readable (a closed gate re-applies nothing: a changed generation restarts
// the debounce, so a default would clear it twice)
fn fault_sat_control_lines(m Model, fb string) []string {
	f := snake(fb)
	x := 'st.fxr_${f}'
	mut g := ['\tif C.xcore_down_read(u32(${m.fault_xdn_off[fb] or { 0 }}), u32(${fault_ctl_lanes(m, fb)}), &${x}[0]) != 0 { // the generations to apply (and held flags), from the owner\'s comm thread']
	for k in 0 .. fault_count(m, fb) {
		g << '\t\tst.fctl_${f}.gen[${k}] = u16(${x}[${2 + k}])'
		g << '\t\tst.fctl_${f}.held[${k}] = ${x}[${2 + k}] & 0x1_0000 != 0'
	}
	g << '\t}'
	return g
}

// fault_sat_report_lines: the satellite FB thread's publish of its reports, after its outputs
fn fault_sat_report_lines(m Model, fb string) []string {
	f := snake(fb)
	w := 'fxw_${f}'
	mut g := ['\tmut ${w} := [${fault_rep_lanes(m, fb)}]u32{}']
	for k in 0 .. fault_count(m, fb) {
		r := 'st.frep_${f}.r[${k}]'
		g << '\t${w}[${2 * k}] = u32(${r}.gen) | if ${r}.failed { u32(0x1_0000) } else { u32(0) }'
		g << '\t${w}[${2 * k + 1}] = u32(${r}.fails) | (u32(${r}.tests) << 16)'
	}
	g << '\tC.xcore_pub_n(u32(${m.fault_xup_off[fb] or { 0 }}), &${w}[0]) // debounced state + counters, to the owner\'s comm thread'
	return g
}
