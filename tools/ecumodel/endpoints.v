module ecumodel

import toml

// A signal's endpoints — the ONE place they are read (REQ-INV-007). A node-internal signal may
// leave `from` and/or `to` out: the producer is then the partition of the FB that writes it and the
// consumer the partition of an FB that reads it, so moving an FB to another core is its `thread`
// line alone. An endpoint that IS written stays the author's word and is checked against the FBs:
// a `from` naming a partition must be the writer's, a `to` naming one must host a reader (when any
// FB reads it), so a move that leaves one stale is refused at generation, never generated wrong.
// A bus or `io` endpoint is never derived — it is wiring, not placement.
pub struct SigEnds {
pub:
	from         string // as written, or the derived partition
	to           string // as written, or the derived partition
	from_derived bool
	to_derived   bool
}

// FbPlace is one FB as placement sees it: its partition and thread, and what its handlers read and
// write — the ONE walk of the FBs that endpoints, loom2v's crossings and the move test all read.
pub struct FbPlace {
pub:
	name   string
	part   string
	thread string
	reads  []string
	writes []string
}

// thread_partitions: each thread's partition, from [[partition.thread]]
fn thread_partitions(doc toml.Doc) map[string]string {
	mut out := map[string]string{}
	for p in toml_arr(doc, 'partition') {
		pm := p.as_map()
		for t in arr_of(pm, 'thread') {
			out[str_of(t.as_map(), 'name')] = str_of(pm, 'name')
		}
	}
	return out
}

// fb_places: every [[fb]] with its partition (through its thread), its reads and writes
pub fn fb_places(doc toml.Doc) []FbPlace {
	thread_part := thread_partitions(doc)
	mut out := []FbPlace{}
	for c in toml_arr(doc, 'fb') {
		cm := c.as_map()
		mut reads := []string{}
		mut writes := []string{}
		for h in arr_of(cm, 'handler') {
			hm := h.as_map()
			for r in arr_of(hm, 'reads') {
				if r.string() !in reads {
					reads << r.string()
				}
			}
			for w in arr_of(hm, 'writes') {
				if w.string() !in writes {
					writes << w.string()
				}
			}
		}
		thr := str_of(cm, 'thread')
		out << FbPlace{
			name:   str_of(cm, 'name')
			part:   thread_part[thr] or { '' }
			thread: thr
			reads:  reads
			writes: writes
		}
	}
	return out
}

// image_partitions_of: the partitions that are their own image — a generated satellite
// (`image = ...`) or a hand-written one (`external = true`); every other partition is the platform
// owner's image. The one statement ecumodel, sysmodel and sysgen read.
pub fn image_partitions_of(doc toml.Doc) map[string]bool {
	mut out := map[string]bool{}
	for p in toml_arr(doc, 'partition') {
		pm := p.as_map()
		if str_of(pm, 'image') != '' || (pm['external'] or { toml.Any(false) }).bool() {
			out[str_of(pm, 'name')] = true
		}
	}
	return out
}

// consumer_partition: the one `to` a signal read by FBs in `readers` (their partitions, FB order)
// takes — a reader on the platform owner's image first, one other than the producer's own partition
// before it (so a same-image reader elsewhere keeps its channel), else any reader; '' when nobody
// reads it. Every other reader is found from the FBs' reads by each consumer, so one is enough.
// sysgen's lowering asks it too (from_part '' for a received signal).
pub fn consumer_partition(from_part string, readers []string, own_image map[string]bool) string {
	owner_side := readers.filter(!(own_image[it] or { false }))
	for group in [owner_side, readers] {
		for r in group {
			if r != from_part {
				return r
			}
		}
		if group.len > 0 {
			return group[0]
		}
	}
	return ''
}

// signal_endpoints: every [[signal]]'s endpoints by name, and why any cannot be settled. A signal
// whose endpoint cannot be derived keeps the other one and reads '' for it, its refusal reported
// once here — so no later check reports a symptom of it.
pub fn signal_endpoints(doc toml.Doc) (map[string]SigEnds, []string) {
	thread_part := thread_partitions(doc)
	mut parts := map[string]bool{}
	for p in toml_arr(doc, 'partition') {
		parts[str_of(p.as_map(), 'name')] = true
	}
	own_image := image_partitions_of(doc)
	part_of := fn [parts, thread_part] (ep string) string {
		if ep in parts {
			return ep
		}
		return thread_part[ep] or { '' }
	}
	fbs := fb_places(doc)
	mut out := map[string]SigEnds{}
	mut errs := []string{}
	for sg in toml_arr(doc, 'signal') {
		sm := sg.as_map()
		name := str_of(sm, 'name')
		if name == '' {
			continue
		}
		writers := fbs.filter(name in it.writes && it.part != '')
		readers := fbs.filter(name in it.reads && it.part != '')
		mut wparts := []string{}
		for w in writers {
			if w.part !in wparts {
				wparts << w.part
			}
		}
		mut from := str_of(sm, 'from')
		mut to := str_of(sm, 'to')
		from_derived := 'from' !in sm
		to_derived := 'to' !in sm
		if from_derived {
			if wparts.len == 0 {
				errs << 'signal "${name}" leaves out `from` and no fb writes it — name its producer (a bus, `io`, or a partition)'
				from = ''
			} else if wparts.len > 1 {
				errs << 'signal "${name}" is written in ${wparts.len} partitions (${wparts.join(', ')}) — a signal has one producer'
				from = ''
			} else {
				from = wparts[0]
			}
		} else if part_of(from) != '' {
			fp := part_of(from)
			for w in writers {
				if w.part != fp {
					errs << 'signal "${name}" declares from = "${from}", but fb "${w.name}" writes it in partition "${w.part}" — name "${w.part}", or leave `from` out to follow the fb'
					break
				}
			}
		}
		if to_derived {
			to = consumer_partition(part_of(from), readers.map(it.part), own_image)
			if to == '' {
				if part_of(from) != '' {
					to = from // written and read nowhere yet: local to its writer
				} else {
					errs << 'signal "${name}" leaves out `to` and no fb reads it — name its consumer (a bus, `io`, or a partition)'
				}
			}
		} else if part_of(to) != '' {
			tp := part_of(to)
			if readers.len > 0 && !readers.any(it.part == tp) {
				errs << 'signal "${name}" declares to = "${to}", but no fb in partition "${tp}" reads it (fb "${readers[0].name}" reads it in "${readers[0].part}") — name "${readers[0].part}", or leave `to` out to follow the fbs'
			}
		}
		out[name] = SigEnds{
			from:         from
			to:           to
			from_derived: from_derived
			to_derived:   to_derived
		}
	}
	return out, errs
}
