// loom2v's `stat` shell command — per-handler run_profiled timing (last/max/mean µs +
// invocation count) read straight from the per-thread Schedulers. This is the shell-served
// cousin of the backlogged HandlerStat `stat` COM endpoint: same data, pull instead of push
// — enough to answer "which handler got slower?" across boards with one command. Generated
// because only the generator knows which handlers registered on which thread's scheduler
// (the labels below are emitted in the SAME partition/fb/handler walk order as the every()
// registrations, so scheduler index i is label i — the same assumption the trace FB hooks
// already rely on).
module main

import toml
import tools.ecumodel

// stat_labels: per-thread 'Fb.handler' labels in registration order (multi), or the single
// partition's full list keyed '' (single).
fn stat_labels(m Model, doc toml.Doc, app_threads []string, multi bool) map[string][]string {
	mut labels := map[string][]string{}
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		if m.part.external[pname] {
			continue // no local scheduler to read stats from
		}
		for c in m.part.by_part[pname] {
			cm := c.as_map()
			fbname := (cm['name'] or { toml.Any('') }).string()
			thr := if multi { m.part.fb_thread[fbname] or { app_threads[0] } } else { '' }
			for h in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hname := (h.as_map()['name'] or { toml.Any('') }).string()
				labels[thr] << '${fbname}.${hname}'
			}
		}
	}
	return labels
}

fn stat_shell_fns(m Model, doc toml.Doc, app_threads []string, multi bool) []string {
	if !m.shell.on {
		return []string{}
	}
	labels := stat_labels(m, doc, app_threads, multi)
	mut g := []string{}
	g << ''
	g << '// stat_vals: one handler line, values only — the caller writes the label first (the'
	g << '// helper deliberately takes no text parameter: this generated file sits inside the'
	g << '// no-alloc lint scan, which bans the heap-backed text type even as a param).'
	g << 'fn stat_vals(mut rsp shell.Rsp, st loom.HandlerStat) {'
	g << '\trsp.write_u32_padded(st.last_us, 7)'
	g << '\trsp.write_u32_padded(st.max_us, 7)'
	g << '\tmean := if st.count > 0 { u32(st.total_us / u64(st.count)) } else { u32(0) }'
	g << '\trsp.write_u32_padded(mean, 7)'
	g << '\trsp.write_u32(st.count)'
	g << '\trsp.nl()'
	g << '}'
	g << ''
	g << 'fn shell_stat_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {'
	g << "\trsp.write('handler             last   max    mean   n (us)')"
	g << '\trsp.nl()'
	if multi {
		for thr in app_threads {
			for i, label in labels[thr] or { []string{} } {
				g << "\trsp.write_padded('${label}', 20)"
				g << '\tstat_vals(mut rsp, g_sched_${thr}.stat(${i}))'
			}
		}
	} else {
		part := m.part.by_part.keys()[0]
		for i, label in labels[''] or { []string{} } {
			g << "\trsp.write_padded('${label}', 20)"
			g << '\tstat_vals(mut rsp, g_sched_${part}.stat(${i}))'
		}
	}
	g << '}'
	return g
}

fn stat_shell_register(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	return ["\tg_sh.register('stat', 'per-handler us: last, max, mean, count', shell_stat_cmd)"]
}
