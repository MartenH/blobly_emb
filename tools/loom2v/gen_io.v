// loom2v's PHYSICAL IO codegen (docs/io.md): parse [[io.*]] points and emit the
// platform io thread — host (file mirror) and ThreadX target (register backend).
// Extracted verbatim from gen.v; same `module main`, so no imports change.
module main

import toml

// IoPoint is one [[io.gpio]] entry, bound one-to-one to the [[signal]] of the same
// name (docs/io.md). ch is the generator-assigned driver channel (array index);
// output comes from the bound signal's direction (to == "io"), never re-declared.
struct IoPoint {
	name        string
	pin         string
	kind        string // 'gpio' | 'adc' | 'pwm' (docs/io.md)
	period_ms   int
	init        bool // gpio output init level
	init_pm     u32  // pwm output init duty (permille)
	freq_hz     int  // pwm carrier
	active_low  bool // pad polarity (REQ-IO-017): logical true = pad LOW
	output      bool
	ch          int
	has_default bool // input only: the port field's pre-first-sample value
	default     bool
	default_u32 u32  // adc: typed degraded-start count (has_default gates it)
}

// parse_io reads [io] (optional core, default 0 — the IO core) and its [[io.gpio]]
// points. Needs sig_of for the direction lookup, so it runs after parse_signals;
// binding/shape/period/exclusivity rules are already enforced by ecumodel.validate.
fn parse_io(doc toml.Doc, sig_of map[string]SigInfo) ([]IoPoint, int) {
	mut points := []IoPoint{}
	io_tbl := doc.value_opt('io') or { return points, 0 }
	iom := io_tbl.as_map()
	core := int((iom['core'] or { toml.Any(0) }).int())
	for kind in ['gpio', 'adc', 'pwm'] {
		for p in (iom[kind] or { toml.Any([]toml.Any{}) }).array() {
			pm := p.as_map()
			name := (pm['name'] or { toml.Any('') }).string()
			si := sig_of[name] or { continue } // one-to-one binding validated upstream
			points << IoPoint{
				name:        name
				pin:         (pm['pin'] or { toml.Any('') }).string()
				kind:        kind
				period_ms:   int((pm['period_ms'] or { toml.Any(0) }).int())
				init:        (pm['init'] or { toml.Any(false) }).bool()
				init_pm:     u32((pm['init'] or { toml.Any(0) }).int())
				freq_hz:     int((pm['freq_hz'] or { toml.Any(0) }).int())
				active_low:  (pm['active_low'] or { toml.Any(false) }).bool()
				output:      si.io_out
				ch:          points.len
				has_default: 'default' in pm
				default:     (pm['default'] or { toml.Any(false) }).bool()
				default_u32: u32((pm['default'] or { toml.Any(0) }).int())
			}
		}
	}
	return points, core
}

// emit_partition_io emits the host platform io thread (docs/io.md): the SINGLE owner of
// every pin touch. It runs at the fastest configured io period and serves each point on
// its own multiple — inputs sample -> publish into the signal channel, outputs acquire
// from the channel -> apply, gated on freshness (until the producing FB has published
// once, the acquire reports no data and the driver keeps holding the configured init).
fn emit_partition_io(m Model, producers []Producer) []string {
	if m.io_points.len == 0 || m.target.on {
		return []string{} // the ThreadX target emits its own io thread in emit_run_target
	}
	mut fastest := m.io_points[0].period_ms
	for pt in m.io_points {
		if pt.period_ms < fastest {
			fastest = pt.period_ms
		}
	}
	mut glue := []string{}
	glue << ''
	glue << 'fn partition_io() {'
	glue << '\tosal.pin_to_core(${m.io_core})'
	glue << '\tmut tick := u64(0)'
	glue << '\tmut sched := loom.Scheduler{} // accounting only — io busy time into the per-core load'
	glue << '\t// monotonic deadline pacing: the file-mirror I/O time must not accumulate as'
	glue << '\t// drift. Sleeping to the deadline BEFORE serving makes the first output apply'
	glue << '\t// land one full period after spawn — the driver-established init observably'
	glue << '\t// holds for >= one io period (REQ-IO-009); inputs are covered by the boot'
	glue << '\t// sample run() published before any app dispatch.'
	glue << '\tmut next_us := osal.now_us()'
	glue << '\tfor {'
	glue << '\t\tnext_us += ${fastest * 1000}'
	glue << '\t\tnow := osal.now_us()'
	glue << '\t\t// timebase-anomaly guard (REQ-IO-024): the missed-period catch-up (next_us +='
	glue << '\t\t// missed*P) lets one bad now sample push the deadline arbitrarily far ahead with'
	glue << '\t\t// no recovery — a sleep-to-deadline would then hang for that long. Re-anchor so'
	glue << '\t\t// next_us is never more than one period ahead (bounds the sleep to <= one period).'
	glue << '\t\tif next_us > now + ${fastest * 1000} { next_us = now + ${fastest * 1000} }'
	glue << '\t\tif next_us > now {'
	glue << '\t\t\tosal.sleep_us(next_us - now)'
	glue << '\t\t} else {'
	glue << '\t\t\t// overrun: skip the MISSED base periods, no burst catch-up — tick'
	glue << '\t\t\t// advances with wall time so (tick+1)%mult gating stays aligned'
	glue << '\t\t\tmissed := (now - next_us) / ${fastest * 1000}'
	glue << '\t\t\ttick += missed'
	glue << '\t\t\tnext_us += missed * ${fastest * 1000}'
	glue << '\t\t}'
	glue << '\t\tloom_t0 := osal.now_us()'
	for pt in m.io_points {
		si := m.sig_of[pt.name] or { continue }
		fld := snake(pt.name)
		mult := pt.period_ms / fastest
		ind := if mult > 1 { '\t\t\t' } else { '\t\t' }
		if mult > 1 {
			// (tick+1): the first serve is one fastest-period after spawn, so a
			// sub-rated point must first fire on its OWN period, not the fastest one
			glue << '\t\tif (tick + 1) % ${mult} == 0 { // ${pt.period_ms} ms point on the ${fastest} ms tick'
		}
		if pt.output {
			glue << '${ind}mut ${fld} := sig.${pt.name}{}'
			glue << '${ind}if osal.${acquire_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld}))) {'
			if pt.kind == 'pwm' {
				glue << '${ind}\tio.pwm_write(${pt.ch}, u32(${fld}.${si.val_field})) // duty permille; freshness-gated'
			} else {
				glue << '${ind}\tio.gpio_write(${pt.ch}, ${fld}.${si.val_field}) // freshness-gated: init holds until the first publish'
			}
			glue << '${ind}}'
		} else if pt.kind == 'adc' {
			glue << '${ind}if ${fld}_v := io.adc_read_checked(${pt.ch}) {'
			glue << '${ind}\tmut ${fld} := sig.${pt.name}{ ${si.val_field}: ${adc_cast(si.val_type)}(${fld}_v) }'
			glue << '${ind}\tosal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
			glue << '${ind}}'
		} else {
			// checked read: only REAL parsed values publish — after a failed boot
			// sample a plain read would fabricate the cfg init as the first sample
			glue << '${ind}if ${fld}_v := io.gpio_read_checked(${pt.ch}) {'
			glue << '${ind}\tmut ${fld} := sig.${pt.name}{ ${si.val_field}: ${fld}_v }'
			glue << '${ind}\tosal.${publish_fn(si.transport)}(${fld}_ch, &${fld}, u8(sizeof(${fld})))'
			glue << '${ind}}'
		}
		if mult > 1 {
			glue << '\t\t}'
		}
	}
	glue << '\t\tloom_t1 := osal.now_us()'
	glue << '\t\tsched.account(loom_t1 - loom_t0, loom_t1) // per-core load'
	for p in producers {
		glue << p.partition_loop_body('io')
	}
	glue << '\t\ttick++'
	glue << '\t}'
	glue << '}'
	return glue
}

// emit_io_target_entry emits the ThreadX platform io thread's entry fn (docs/io.md on
// target): the same fastest-period loop + (tick+1)%mult sub-rating as the host emitter,
// paced to a monotonic deadline on the DWT timebase (tx_thread_sleep is relative, so a
// fixed sleep would accumulate serve-time as drift). Values cross on the target IOC pool
// cells; outputs are freshness-gated through ioc_get_ever (init holds until the first
// publish), inputs keep the checked read (only REAL values publish — uniform with the
// host, and the port contract's failure leg stays honest on target too). with_load (the
// comm-thread target): serve time is accounted like an FB thread's pass and published to
// io's own load slot — the slot AFTER the FB threads, matching its manifest row.
// adc_cast: the value cast for an ADC point's signal field — adc_read returns
// u32, the field is u16 or u32 (validated), so u16 fields narrow explicitly.
// io_cfg_param: the kind param for io.cfg — pwm carrier freq_hz, or an ADC's
// full-scale max (so the host mirror rejects an out-of-width value rather than
// letting the u16 glue cast truncate it, codex emb#152). 0 for gpio.
fn io_cfg_param(pt IoPoint, m Model) string {
	if pt.kind == 'pwm' {
		return 'u32(${pt.freq_hz})'
	}
	if pt.kind == 'adc' {
		si := m.sig_of[pt.name] or { SigInfo{} }
		return if si.val_type == 'u16' { 'u32(65535)' } else { 'u32(0xffffffff)' }
	}
	return 'u32(0)'
}

fn adc_cast(typ string) string {
	return if typ == 'u16' { 'u16' } else { 'u32' }
}

fn emit_io_target_entry(m Model, ioc_idx map[string]int, with_load bool, load_slot int) []string {
	mut g := []string{}
	if m.io_points.len == 0 {
		return g
	}
	// The exec counter (io_exec_add) is needed by TWO consumers: load telemetry (with_load) and
	// the profiled FB dispatch, whose run_profiled_excl subtracts it per handler. With trace
	// level="all" it must be published even when nothing ships CpuLoad — otherwise the
	// preemption clock reads zero and io preemption is silently charged to the FBs again
	// (codex on #264).
	excl := m.trace.on && m.trace.level == 'all'
	mut fastest := m.io_points[0].period_ms
	for pt in m.io_points {
		if pt.period_ms < fastest {
			fastest = pt.period_ms
		}
	}
	g << 'fn io_thread_entry(input u32) {'
	g << '\tmut tick := u64(0)'
	if with_load {
		g << '\tmut sched := &g_sched_io // load accounting only (no handlers): bss, not this frame'
	}
	g << '\t// monotonic deadline pacing: sleeping the remaining-to-deadline ticks (rounded'
	g << '\t// UP: late <= 1 tick, never early) keeps the cadence drift-free under serve'
	g << '\t// jitter. Sleeping BEFORE serving makes the first output apply land one full io'
	g << '\t// period after resume — the driver-established init observably holds for >= one'
	g << '\t// period (REQ-IO-009); inputs are covered by the boot sample published in'
	g << '\t// tx_application_define before any thread ran.'
	g << '\tmut next_us := C.board_now_us()'
	g << '\tfor {'
	g << '\t\tnext_us += ${fastest * 1000}'
	g << '\t\tmut now := C.board_now_us()'
	g << '\t\t// timebase-anomaly guard (REQ-IO-024): the missed-period catch-up below does'
	g << '\t\t// next_us += missed*P, so one anomalous board_now_us() sample can push the'
	g << '\t\t// deadline arbitrarily far ahead and it never recovers — the sleep would then'
	g << '\t\t// be a monster tick count that parks this thread for days (bench: 1.27e9 ticks,'
	g << '\t\t// all io frozen while comm/app ran). Re-anchor BEFORE EVERY sleep, not just the'
	g << '\t\t// first sample: the post-wake refresh could itself be the bad low sample and'
	g << '\t\t// re-inflate the gap (codex #155). next_us <= now+P => every sleep <= one period.'
	g << '\t\tfor {'
	g << '\t\t\tif next_us > now + ${fastest * 1000} { next_us = now + ${fastest * 1000} }'
	g << '\t\t\tif next_us <= now { break } // deadline reached'
	g << '\t\t\tC._tx_thread_sleep(u32((next_us - now + 999) / 1000)) // 1 kHz kernel tick'
	g << '\t\t\tnow = C.board_now_us() // a tick-phase-early wake must not serve before the deadline'
	g << '\t\t}'
	g << '\t\t// past the deadline now (the wait loop exits at now >= next_us). Skip the'
	g << '\t\t// MISSED WHOLE periods, no burst catch-up — tick advances with wall time'
	g << '\t\t// so (tick+1)%mult gating stays aligned; a sub-period lateness serves now'
	g << '\t\t// and the next sleep re-anchors (one shortened gap, the cadence tradeoff).'
	g << '\t\tmissed := (now - next_us) / ${fastest * 1000}'
	if with_load {
		g << '\t\tif missed > 0 {'
		g << '\t\t\tsched.mark_overrun() // a WHOLE period slipped (not the sub-tick'
		g << '\t\t\t// wake rounding, which fires every healthy cycle — codex emb#150 r9)'
		g << '\t\t}'
	}
	g << '\t\ttick += missed'
	g << '\t\tnext_us += missed * ${fastest * 1000}'
	if with_load || excl {
		g << '\t\tt0 := C.board_now_us()'
	}
	for pt in m.io_points {
		idx := ioc_idx[pt.name] or { continue }
		fld := snake(pt.name)
		mult := pt.period_ms / fastest
		ind := if mult > 1 { '\t\t\t' } else { '\t\t' }
		if mult > 1 {
			// (tick+1): the first serve is one fastest-period after resume, so a
			// sub-rated point must first fire on its OWN period, not the fastest one
			g << '\t\tif (tick + 1) % ${mult} == 0 { // ${pt.period_ms} ms point on the ${fastest} ms tick'
		}
		if pt.output {
			g << '${ind}mut ${fld}_a := u32(0)'
			g << '${ind}mut ${fld}_b := u32(0)'
			g << '${ind}if C.ioc_get_ever(${idx}, &${fld}_a, &${fld}_b) != 0 {'
			if pt.kind == 'pwm' {
				g << '${ind}\tio.pwm_write(${pt.ch}, ${fld}_a) // duty permille; freshness-gated: init holds until the first publish'
			} else {
				g << '${ind}\tio.gpio_write(${pt.ch}, ${fld}_a != 0) // freshness-gated: init holds until the first publish'
			}
			g << '${ind}}'
		} else if pt.kind == 'adc' {
			// analog input: publish only a REAL conversion (checked) — a degraded
			// converter must not push a fabricated zero (codex emb#152); the cell
			// keeps its last published value / declared default meanwhile.
			g << '${ind}if ${fld}_v := io.adc_read_checked(${pt.ch}) {'
			g << '${ind}\tC.ioc_pub(${idx}, ${fld}_v, u32(0))'
			g << '${ind}}'
		} else {
			g << '${ind}if ${fld}_v := io.gpio_read_checked(${pt.ch}) {'
			g << '${ind}\tC.ioc_pub(${idx}, if ${fld}_v { u32(1) } else { u32(0) }, u32(0))'
			g << '${ind}}'
		}
		if mult > 1 {
			g << '\t\t}'
		}
	}
	if with_load || excl {
		g << '\t\tt1 := C.board_now_us()'
		g << '\t\tC.io_exec_add(u32(t1 - t0)) // publish exec so the FB thread can subtract'
		g << '\t\t// this preemption from its wall bracket (no double-count, emb#150 r10)'
	}
	if with_load {
		// io's serve time lands in CpuLoad through the SAME scratch seam as the FB
		// threads: account the bracket, publish to io's slot; the comm thread sums.
		g << "\t\tsched.account(t1 - t0, t1) // serve time -> the io thread's load slot"
		g << '\t\tif t1 - t0 > ${fastest * 1000} {'
		g << '\t\t\tsched.mark_overrun() // the SERVE exhausted its base-period budget'
		g << '\t\t\t// (the 1..2-period case floor(missed) missed — codex emb#150 r6/r9)'
		g << '\t\t}'
		g << '\t\tC.load_pub_slot(${load_slot}, u32(sched.load_permille()), u32(sched.load_permille_100ms()),'
		g << '\t\t\tu32(sched.load_permille_1s()), u32(sched.load_permille_10s()), sched.overruns())'
	}
	g << '\t\ttick++'
	g << '\t}'
	g << '}'
	g << ''
	return g
}

// emit_io_target_boot emits the io cfg + init + one synchronous boot publish, injected at
// the TOP of tx_application_define — before any thread is created, so it runs to completion
// before application dispatch can begin (REQ-IO-009: platform first, app after). Outputs
// hold their configured init from io.init() on; each input gets ONE boot sample so the
// first activation never reads an empty cell. An INPUT failure bumps the exported
// io_startup_faults counter (degraded, observable start); an OUTPUT cfg/init failure
// HALTS before app dispatch — REQ-IO-009 has no safe-start exception for an actuator
// that never reached its init level (SWD reads the counter).
fn emit_io_target_boot(m Model, ioc_idx map[string]int) []string {
	mut g := []string{}
	if m.io_points.len == 0 {
		return g
	}
	mut has_output := false
	for pt in m.io_points {
		if pt.output {
			has_output = true
		}
	}
	g << '\t// io BEFORE the app threads exist (REQ-IO-009): declare + init the points —'
	g << '\t// outputs hold their configured init from here — then publish ONE boot sample'
	g << '\t// per input. Input failures count observably (degraded start); an output'
	g << '\t// fault halts BEFORE app dispatch — but only AFTER declaring the rest and'
	g << '\t// running init, so every VALID output still reaches its declared level'
	g << '\t// instead of floating through the halt (codex on emb#150).'
	if has_output {
		g << '\tmut io_out_fault := false'
	}
	for pt in m.io_points {
		al := if pt.active_low { 1 } else { 0 }
		kind_n := if pt.kind == 'adc' { 1 } else if pt.kind == 'pwm' { 2 } else { 0 }
		iv := if pt.kind == 'pwm' { pt.init_pm } else if pt.init { u32(1) } else { u32(0) }
		g << "\tif !io.cfg(${pt.ch}, '${pt.name}', '${pt.pin}', ${pt.output}, ${iv}, ${al}, ${kind_n}, ${io_cfg_param(pt, m)}) {"
		g << '\t\tio_startup_faults++'
		if pt.output {
			g << '\t\tio_out_fault = true // halt LATER: first let the valid outputs init'
		}
		g << '\t}'
	}
	g << '\tif !io.init() {'
	g << '\t\tio_startup_faults++'
	if has_output {
		g << '\t\tio_out_fault = true'
	}
	g << '\t}'
	if has_output {
		g << '\tif io_out_fault {'
		g << '\t\tfor {} // an OUTPUT never reached its init level (REQ-IO-009): no app'
		g << '\t\t// dispatch — the valid outputs sit at their declared init, the fault'
		g << '\t\t// counter reads via SWD'
		g << '\t}'
	}
	for pt in m.io_points {
		if pt.output {
			continue
		}
		idx := ioc_idx[pt.name] or { continue }
		fld := snake(pt.name)
		if pt.kind == 'adc' {
			// checked: publish only a REAL first conversion (REQ-IO-018). If none
			// landed, publish the declared default, else count a fault (never a
			// fabricated zero — codex emb#152).
			g << '\tif boot_${fld}_v := io.adc_read_checked(${pt.ch}) {'
			g << '\t\tC.ioc_pub(${idx}, boot_${fld}_v, u32(0))'
			g << '\t} else {'
			g << '\t\tio_startup_faults++ // no first conversion: publish NOTHING (the'
			g << '\t\t// port initializer holds the declared default; a published default'
			g << '\t\t// would mark a fabricated sample fresh — codex emb#152)'
			g << '\t}'
		} else {
			g << '\tif boot_${fld}_v := io.gpio_read_checked(${pt.ch}) {'
			g << '\t\tC.ioc_pub(${idx}, if boot_${fld}_v { u32(1) } else { u32(0) }, u32(0))'
			g << '\t} else {'
			g << '\t\tio_startup_faults++ // unreadable at boot: publish NOTHING (no fabricated sample)'
			g << '\t}'
		}
	}
	return g
}

// emit_io_target_create emits the io thread's create + resume, AFTER the app-thread
// creates in tx_application_define: AUTO_START OFF then an explicit resume, so the
// startup ordering (cfg/init/boot publish first) is in the code path, not implied by
// scheduler timing. The kernel starts only after tx_application_define returns; the io
// thread then outranks every FB thread, so its cadence never waits on an app pass.
fn emit_io_target_create(io_prio int) []string {
	mut g := []string{}
	g << "\tC._tx_thread_create(&g_io_tcb[0], c'io', io_thread_entry, u32(0),"
	g << '\t\t&g_io_stack[0], u32(g_io_stack.len), u32(${io_prio}), u32(${io_prio}), u32(0), u32(0))'
	g << '\tC._tx_thread_resume(&g_io_tcb[0])'
	return g
}
