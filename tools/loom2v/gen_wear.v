// The journal's WEAR CHECK (REQ-NVM-010, docs/nvm.md "Wear, proven per configuration"): every
// writer of the NvM journal in ONE computation — the persisted signals, the clean markers the
// flush choreography lays, the fault memory (status image, snapshot blocks, tombstones), the
// parameters and the 0x27 failed-key state — against the sector pair's erase budget, at
// generation. A configuration that cannot last `[nvm] min_years` is refused, naming each contributor's share; one that can prints the
// same numbers, so the review sees them either way.
//
// Each rate is what the generated code does, bounded per event: a "now" signal's floored put, a
// choreography at each NM sleep edge, after each write made in bus sleep and before each
// ECUReset, the fault memory's per-cycle bound (comm/fault cycle_images, held to it by
// persist_test.v), one record per accepted 0x2E, and for the 0x27 failed-key state at most
// security_attempts records per served level until that level's correct key and attempts + 1 per
// correct-key unlock (held by comm/uds sa_store_test.v). What only the VEHICLE knows — how often
// it begins an operation cycle, how often a tester resets, clears, toggles 0x85, codes or unlocks
// 0x27 — is a declared assumption ([nvm.assume], per day, conservative defaults) printed beside the
// result.
//
// The same rates are held to the journal's room between two ERASE POINTS (REQ-NVM-016): no erase runs
// in a run (docs/nvm.md "No erase at run time"), so the average operation cycle's writes at the
// assumed rates must fit what the journal takes between two of them (nvm.run_capacity), or they
// would be refused until the next — a necessary bound, not a sufficient one: a cycle may carry a
// day's clears. The report states that room, and how many 0x14 at their worst fit beside the
// average cycle — the bound a long bench loop meets in one power cycle (#393).
module main

import toml
import tools.cfgschema
import comm.fault
import comm.param
import comm.uds
import nvm

// WearAssume: the vehicle's rates, per day — what the code cannot know ([nvm.assume]).
struct WearAssume {
mut:
	cycles   u32 = 144 // operation cycles: NM wake -> sleep, or power-ups (one every 10 min, all day)
	resets   u32 = 24 // ECUResets (0x11) a tester asks for
	clears   u32 = 24 // 0x14 ClearDiagnosticInformation
	settings u32 = 24 // 0x85 ControlDTCSetting changes
	codings  u32 = 24 // accepted 0x2E codings of a [[param]]
	unlocks  u32 = 24 // correct-key unlocks (0x27 keys, or 0x29 proofs), all levels
	declared []string // the keys the configuration states (the rest are the defaults)
}

// the [nvm.assume] keys: the schema's (tools/cfgschema)
const wear_assume_keys = cfgschema.ecu.table('nvm_assume').names()

// parse_wear_assume: [nvm.assume], each key a bounded non-negative integer per day.
fn parse_wear_assume(nm map[string]toml.Any) WearAssume {
	mut a := WearAssume{}
	av := nm['assume'] or { return a }
	if av !is map[string]toml.Any {
		panic('loom2v: [nvm] assume must be a table ([nvm.assume]) of ${wear_assume_keys}')
	}
	am := av.as_map()
	for k, _ in am {
		if k !in wear_assume_keys {
			panic('loom2v: [nvm.assume] unknown key "${k}" (allowed: ${wear_assume_keys})')
		}
		a.declared << k
	}
	a.cycles = u32(schema_int(am, 'nvm_assume', 'cycles_per_day', a.cycles, '[nvm.assume]'))
	a.resets = u32(schema_int(am, 'nvm_assume', 'resets_per_day', a.resets, '[nvm.assume]'))
	a.clears = u32(schema_int(am, 'nvm_assume', 'clears_per_day', a.clears, '[nvm.assume]'))
	a.settings = u32(schema_int(am, 'nvm_assume', 'setting_changes_per_day', a.settings, '[nvm.assume]'))
	a.codings = u32(schema_int(am, 'nvm_assume', 'codings_per_day', a.codings, '[nvm.assume]'))
	a.unlocks = u32(schema_int(am, 'nvm_assume', 'unlocks_per_day', a.unlocks, '[nvm.assume]'))
	return a
}

// WearShare is one contributor: what it is, how it is counted, and its records per hour.
struct WearShare {
	what     string
	how      string
	per_hour f64
}

// Wear is the computation's result: the contributors, the compaction interval, the lifetime.
struct Wear {
	shares    []WearShare
	total     f64 // records per hour
	live      int // the live set, in records (copied by every compaction)
	usable    int // records written between two compactions, at least
	erases    f64 // erases of each sector of the pair per year
	years     f64
	per_run   int // records the journal takes between two erase points, at least (nvm.run_capacity)
	per_cycle f64 // records the average operation cycle writes at the assumed rates
	clear     int // records one 0x14 writes at its worst, awake (0 without a persisted fault memory)
	points    string // what the erase points are, as printed
	assumed   []string // the assumptions the rates used, as printed
	unwritten string // what is never written, said so the reader does not look for it
}

const hours_per_year = 24.0 * 365.0

// journal_wear computes the journal's worst-case write rate and lifetime (nvm_on(m) images only).
fn journal_wear(m Model, doc toml.Doc) Wear {
	a := m.nvm.assume
	nm := m.nm.on
	fp := fault_persist_on(m)
	params := m.target.threadx && m.params.len > 0
	// ECUReset is served only by a node with a diagnostic connection (diag_target_reset)
	served := m.isotp_conns.len > 0
	// the vehicle's rates, per hour; a reset ends an operation cycle as power-off does
	resets := if served { f64(a.resets) / 24.0 } else { 0.0 }
	cycles := f64(a.cycles) / 24.0 + resets
	clears := if fp { f64(a.clears) / 24.0 } else { 0.0 }
	settings := if fp { f64(a.settings) / 24.0 } else { 0.0 }
	codings := if params { f64(a.codings) / 24.0 } else { 0.0 }
	sa := sa_persist_on(m)
	// the 0x27 state (which counts a 0x29 node's failed proofs alike): per served level at most
	// `attempts` rises between two correct keys (one per wrong key below the limit) and one clear by the correct key that follows them, however many
	// wrong keys a tester sends — so attempts + 1 per unlock, plus the `attempts` per level a tester
	// may leave counted after the last one (once over the lifetime: nothing but a correct key clears
	// them, and they saturate)
	sa_attempts := int(uds.attempts_of(u8(m.uds.security_attempts)))
	sa_nlevels := sa_level_count(m)
	life_hours := if m.nvm.min_years > 0 { f64(m.nvm.min_years) * hours_per_year } else { hours_per_year }
	sa_writes := if sa {
		f64(a.unlocks) / 24.0 * f64(sa_attempts + 1) + f64(sa_nlevels * sa_attempts) / life_hours
	} else {
		0.0
	}
	mut assumed := ['${a.cycles} operation cycles/day${wear_default(a, 'cycles_per_day')}']
	if served {
		assumed << '${a.resets} ECUResets/day${wear_default(a, 'resets_per_day')}'
	}
	if fp {
		assumed << '${a.clears} 0x14 clears/day${wear_default(a, 'clears_per_day')}'
		assumed << '${a.settings} 0x85 changes/day${wear_default(a, 'setting_changes_per_day')}'
	}
	if params {
		assumed << '${a.codings} 0x2E codings/day${wear_default(a, 'codings_per_day')}'
	}
	if sa {
		way := if m.uds.auth() { '0x29' } else { '0x27' }
		assumed << '${a.unlocks} ${way} unlocks/day${wear_default(a, 'unlocks_per_day')}'
	}
	floor := f64(m.nvm.min_write_ms)
	// the "now" signals' own floored puts, and how many land inside the cycle-end barrier's grace
	mut own_puts := 0.0
	mut grace_puts := 0.0
	grace_ms := f64(m.fault_grace_us) / 1000.0
	for sname in m.nvm_names {
		si := m.sig_of[sname] or { continue }
		if si.persist != 'now' {
			continue
		}
		period := f64(writer_period_ms(doc, sname))
		eff := if period > floor { period } else { floor }
		own_puts += 3600_000.0 / eff
		grace_puts += f64(int(grace_ms / eff) + 1)
	}
	// the fault memory, per hour: its writes by kind (comm/fault's per-event bounds)
	n := m.faults.len
	mut nsnap := 0
	mut snap_recs := 0 // records of one capture of every snapshot DTC
	mut img_recs := 0
	mut images := 0.0
	mut snaps := 0.0 // snapshot block writes
	mut snap_rate := 0.0 // their records
	if fp {
		img_recs = chain_records(2 + n * fault.image_rec)
		for f in m.faults {
			if f.freeze.len > 0 {
				nsnap++
				snap_recs += fault_snapshot_records(m, f)
			}
		}
		// a flush writes the image once more when only occurrence counters moved, and only while a
		// cycle is open or ending: the NM sleep edges and the "now" puts in the barrier's grace,
		// every ECUReset, a tester's write in bus sleep, and the memory's own block writes there
		mut flushes := resets
		if nm {
			flushes += cycles * (2 + grace_puts) + clears + settings + codings + (cycles + clears) * f64(2 * nsnap * fault.captures_per_cycle)
		}
		images = cycles * f64(fault.cycle_images(n, nsnap)) + clears * f64(fault.clear_images(n, nsnap)) + settings * f64(fault.setting_images) + flushes
		snaps = (cycles + clears) * f64(nsnap * fault.captures_per_cycle)
		snap_rate = (cycles + clears) * f64(snap_recs * fault.captures_per_cycle)
	}
	tombs := snaps // every snapshot block is tombstoned at most once
	// the flush choreography's runs (each lays one clean marker): every ECUReset, and with NM both
	// sleep edges of every cycle and every write that can land in bus sleep — a "now" put, a coding,
	// a 0x27 state write, any of the fault memory's writes (its cycle end lands there by design)
	mut choreo := resets
	if nm {
		choreo += cycles * 2 + own_puts + codings + sa_writes
		if fp {
			choreo += images + snaps + tombs
		}
	}
	mut shares := []WearShare{}
	for sname in m.nvm_names {
		si := m.sig_of[sname] or { continue }
		period := writer_period_ms(doc, sname)
		// an interrupt-driven writer has no period: nothing caps its changes
		changes := if period > 0 { 3600_000.0 / f64(period) } else { 1.0e18 }
		// a write needs a change since the last one: at most the writer's own rate, whoever writes
		mut writes := choreo // the choreography flushes it whenever it changed
		mut how := 'flushed by ${choreo:.1} choreography runs/h'
		if si.persist == 'now' {
			eff := if f64(period) > floor { f64(period) } else { floor }
			own := 3600_000.0 / eff
			if nm {
				// every put may land in bus sleep, so the runs count each put already
				how = 'a write per choreography run (${choreo:.1}/h), its own floored puts among them (every ${eff:.0} ms: writer ${period} ms, floor ${m.nvm.min_write_ms} ms)'
			} else {
				writes += own // without NM no put runs the choreography: its own puts come on top
				how = 'floored put every ${eff:.0} ms (writer ${period} ms, floor ${m.nvm.min_write_ms} ms) + ${how}'
			}
		}
		if changes < writes {
			writes = changes
			how += ", capped by its writer's ${period} ms"
		}
		shares << WearShare{
			what: 'signal "${sname}" (persist = "${si.persist}")'
			how: how
			per_hour: writes * f64(chain_records(si.packed_size()))
		}
	}
	if choreo > 0 {
		shares << WearShare{
			what: 'clean markers'
			how: '${choreo:.1} choreography runs/h: ECUResets' + if nm {
				', 2 sleep edges a cycle and every write that can land in bus sleep'} else {
				''}
			per_hour: choreo
		}
	}
	if fp {
		shares << WearShare{
			what: 'fault memory status image (${2 + n * fault.image_rec} B = ${img_recs} records)'
			how: '${images:.1} writes/h: ${fault.cycle_images(n, nsnap)} a cycle (start, end, first test + first failure of ${n} DTCs, ${nsnap} snapshot claims), ${fault.clear_images(n, nsnap)} a 0x14, 1 a 0x85, 1 a flush that carries deferred occurrence counters'
			per_hour: images * f64(img_recs)
		}
		if nsnap > 0 {
			shares << WearShare{
				what: 'fault memory snapshots (${nsnap} DTCs, ${snap_recs} records a set)'
				how: 'one capture per snapshot DTC a cycle and a 0x14 (${snaps:.1} blocks/h), each tombstoned once'
				per_hour: snap_rate + tombs
			}
		}
	}
	if params {
		recs := chain_records(param.max_record) // a parameter's record, at its widest
		shares << WearShare{
			what: 'parameters (${m.params.len})'
			how: 'one ${recs}-record write per accepted 0x2E coding'
			per_hour: codings * f64(recs)
		}
	}
	if sa {
		shares << WearShare{
			what: 'the 0x27 state (${uds.sa_record_len} B = ${chain_records(uds.sa_record_len)} record)'
			how: 'at most ${sa_attempts} per served level until its correct key (${sa_nlevels} levels, once over min_years) and ${sa_attempts + 1} per correct-key unlock (${a.unlocks}/day)'
			per_hour: sa_writes * f64(chain_records(uds.sa_record_len))
		}
	}
	mut total := 0.0
	for s in shares {
		total += s.per_hour
	}
	live := journal_live_records(m)
	// records written between two compactions, at least: with NM the journal compacts when the
	// sector is full (a chain that does not fit at the end wastes its parts but one); without NM it
	// also compacts at every boot that finds less than half a sector free (nvm_boot_lines)
	mut waste := 0
	for s in [img_recs, fault_widest_snapshot(m), chain_records(param.max_record)] {
		if s - 1 > waste {
			waste = s - 1
		}
	}
	slots := int(m.nvm.sector_records)
	usable := if nm { slots - live - waste } else { slots / 2 - live }
	// each compaction erases one sector, and the pair alternates: each sector sees half of them
	erases := if usable > 0 { total / f64(usable) * hours_per_year / 2.0 } else { 0.0 }
	years := if erases > 0 { f64(m.nvm.endurance) / erases } else { 1.0e9 }
	// between two erase points (docs/nvm.md "No erase at run time"): without NM the boot leaves half
	// a sector free beside a clean partner (nvm boot_erase_point), with NM a sleep edge leaves the
	// partner clean and the active sector anywhere; an ECUReset's flush erases on both
	start := if nm { u32(0) } else { u32(slots / 2) }
	per_run := int(nvm.run_capacity(u32(slots), u32(live), u32(waste), start))
	// a 0x14 at its worst, awake (in bus sleep each write lays a marker too): its image and every
	// DTC's requalification, each snapshot DTC's new capture and the tombstone of the block it
	// replaces
	clear := if fp {
		fault.clear_images(n, nsnap) * img_recs + (snap_recs + nsnap) * fault.captures_per_cycle
	} else {
		0
	}
	return Wear{
		shares: shares
		total: total
		live: live
		usable: usable
		erases: erases
		years: years
		per_run: per_run
		per_cycle: total / cycles
		clear: clear
		points: (if nm { 'a sleep edge' } else { 'a power-up' }) + if served { ' or an ECUReset' } else { '' }
		assumed: assumed
		unwritten: if fp {
			'debounce counters are never written; the aging and failed-cycle counters ride in the status image'} else {
			''}
	}
}

fn wear_default(a WearAssume, key string) string {
	return if key in a.declared { '' } else { ' (default)' }
}

// fault_snapshot_records: the journal records one snapshot block of fault f occupies.
fn fault_snapshot_records(m Model, f FaultCfg) int {
	mut s := fault.Slot{}
	for n in fault_freeze_lens(m, f) {
		s.freeze_len[s.nfreeze] = u8(n)
		s.nfreeze++
	}
	return chain_records(s.block_len())
}

// fault_widest_snapshot: the most records one snapshot block takes (0 without a persisted one).
fn fault_widest_snapshot(m Model) int {
	if !fault_persist_on(m) {
		return 0
	}
	mut w := 0
	for f in m.faults {
		if f.freeze.len > 0 {
			r := fault_snapshot_records(m, f)
			if r > w {
				w = r
			}
		}
	}
	return w
}

// wear_lines: the report — the result, each contributor with its share, the assumptions.
fn wear_lines(m Model, w Wear) []string {
	mut out := [
		'[nvm] wear (REQ-NVM-010): ${w.total:.1} records/h into ${m.nvm.sector_records}-record sectors, a compaction every ${w.usable} records or more (live set ${w.live}) = ${w.erases:.0} erases a sector a year: ${w.years:.1} years at ${m.nvm.endurance} cycles (min_years ${m.nvm.min_years})',
	]
	for s in w.shares {
		pct := if w.total > 0 { 100.0 * s.per_hour / w.total } else { 0.0 }
		out << '  ${s.what}: ${s.per_hour:.1} records/h (${pct:.1}%) — ${s.how}'
	}
	mut run := '  between two erase points (${w.points}): at least ${w.per_run} records, ${w.per_cycle:.0} an average cycle at the assumed rates'
	if w.clear > 0 {
		beside := int(f64(w.per_run) - w.per_cycle)
		n := if beside > 0 { beside / w.clear } else { 0 }
		run += ' — room beside it for ${n} 0x14 at their worst (${w.clear} records each, awake: the image, every DTC\'s requalification, the snapshots)'
	}
	out << run
	out << "  assumed ([nvm.assume], the vehicle's): ${w.assumed.join(', ')}"
	if w.unwritten != '' {
		out << '  ${w.unwritten}'
	}
	return out
}

// check_journal_wear: the wear check, after every block is derived — refused below min_years,
// otherwise the report, which main prints once generation has succeeded (syscheck reads every
// "loom2v:" line of a failed run as an error, so a passing report must not precede a later one).
// Every line of a refusal carries the prefix, so syscheck keeps the shares with it.
fn check_journal_wear(m Model, doc toml.Doc) []string {
	if !nvm_on(m) {
		return []string{}
	}
	w := journal_wear(m, doc)
	lines := wear_lines(m, w).map('loom2v: ${it}')
	if w.usable <= 0 {
		panic('loom2v: [nvm] the live set (${w.live} records) leaves no room between compactions in a ${m.nvm.sector_records}-record sector — without NM the journal compacts at every boot that finds less than half a sector free; grow the sectors\n' + lines.join('\n'))
	}
	if w.per_cycle > f64(w.per_run) {
		panic('loom2v: [nvm] a cycle outgrows the journal — at the assumed rates the average operation cycle writes ${w.per_cycle:.0} records, and between two erase points (${w.points}) the journal takes ${w.per_run}, so its writes would be refused until the next one (0x22 to a tester). Grow the sectors, raise min_write_ms, persist fewer "now" signals, or state the vehicle\'s real rates in [nvm.assume]:\n' + lines.join('\n'))
	}
	if w.years < f64(m.nvm.min_years) {
		panic('loom2v: [nvm] wear check failed — ${w.years:.1} years < min_years ${m.nvm.min_years}. Raise min_write_ms, grow the sectors, persist fewer "now" signals, or state the vehicle\'s real rates in [nvm.assume]:\n' + lines.join('\n'))
	}
	return lines
}
