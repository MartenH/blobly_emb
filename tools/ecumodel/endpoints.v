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

// fb_placement: each FB's partition (through its thread), with what its handlers read and write.
struct FbPlace {
	name   string
	part   string
	reads  []string
	writes []string
}

fn fb_places(doc toml.Doc, thread_part map[string]string) []FbPlace {
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
		out << FbPlace{
			name:   str_of(cm, 'name')
			part:   thread_part[str_of(cm, 'thread')] or { '' }
			reads:  reads
			writes: writes
		}
	}
	return out
}

// signal_endpoints: every [[signal]]'s endpoints by name, and why any cannot be settled. The
// derived consumer prefers a reader on the owner image (a partition without `image =` or
// `external = true`), else the first reader, else the producer itself; readers past it are found
// from the FBs' reads by every consumer, so one `to` is enough.
pub fn signal_endpoints(doc toml.Doc) (map[string]SigEnds, []string) {
	mut thread_part := map[string]string{}
	mut parts := map[string]bool{}
	mut own_image := map[string]bool{}
	for p in toml_arr(doc, 'partition') {
		pm := p.as_map()
		pname := str_of(pm, 'name')
		parts[pname] = true
		if str_of(pm, 'image') != '' || (pm['external'] or { toml.Any(false) }).bool() {
			own_image[pname] = true
		}
		for t in arr_of(pm, 'thread') {
			thread_part[str_of(t.as_map(), 'name')] = pname
		}
	}
	part_of := fn [parts, thread_part] (ep string) string {
		if ep in parts {
			return ep
		}
		return thread_part[ep] or { '' }
	}
	fbs := fb_places(doc, thread_part)
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
				continue
			}
			if wparts.len > 1 {
				errs << 'signal "${name}" is written in ${wparts.len} partitions (${wparts.join(', ')}) — a signal has one producer'
				continue
			}
			from = wparts[0]
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
			mut pick := ''
			for r in readers {
				if !(own_image[r.part] or { false }) {
					pick = r.part
					break
				}
			}
			if pick == '' && readers.len > 0 {
				pick = readers[0].part
			}
			to = if pick != '' { pick } else { from }
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
