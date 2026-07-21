// dbcmerge — merge several DBC files into one (multi-node P2c/dissolution). A gateway
// speaks a DBC per bus; loom2v + dbc2cfg consume ONE DBC, so the build merges its
// buses' DBCs (each frame keyed by name, ids unique across the set) into a single file
// that carries every frame/signal. Text-level: union BU_ nodes, concatenate BO_/SG_
// blocks (rejecting a duplicate CAN id), and carry the value tables + attributes.
//
//   v run tools/dbcmerge/gen.v <out.dbc> <in1.dbc> <in2.dbc> [...]
module main

import os

fn main() {
	if os.args.len < 4 {
		eprintln('usage: dbcmerge <out.dbc> <in1.dbc> <in2.dbc> [...]')
		exit(2)
	}
	out := os.args[1]
	ins := os.args[2..]

	mut nodes := []string{} // BU_ union, order-stable
	mut node_seen := map[string]bool{}
	mut blocks := []string{} // each BO_ header + its SG_/CM_ lines, joined
	mut id_owner := map[u32]string{} // CAN id -> frame name (reject a collision)
	mut ba_def := []string{} // BA_DEF_ / BA_DEF_DEF_ (deduped by exact text)
	mut ba_def_seen := map[string]bool{}
	mut vals := []string{} // VAL_ tables + BA_ attribute values

	for path in ins {
		text := os.read_file(path) or {
			eprintln('dbcmerge: read ${path}: ${err}')
			exit(1)
		}
		lines := text.split_into_lines()
		mut i := 0
		for i < lines.len {
			line := lines[i]
			t := line.trim_space()
			if t.starts_with('BU_:') {
				for n in t[4..].fields() {
					if n !in node_seen {
						node_seen[n] = true
						nodes << n
					}
				}
				i++
				continue
			}
			if t.starts_with('BO_ ') {
				f := t.split(' ')
				id := u32(f[1].u64())
				name := if f.len > 2 { f[2].trim_right(':') } else { '?' }
				if prev := id_owner[id] {
					eprintln('dbcmerge: CAN id ${f[1]} is used by both "${prev}" and "${name}" across the merged DBCs — ids must be unique')
					exit(1)
				}
				id_owner[id] = name
				// the BO_ line plus every following ` SG_`/`CM_ SG_` line (the message body)
				mut blk := [line]
				mut j := i + 1
				for j < lines.len {
					bt := lines[j].trim_space()
					if bt.starts_with('SG_ ') || bt.starts_with('CM_ SG_') {
						blk << lines[j]
						j++
						continue
					}
					if bt == '' {
						break
					}
					break
				}
				blocks << blk.join('\n')
				i = j
				continue
			}
			if t.starts_with('BA_DEF_') {
				if t !in ba_def_seen {
					ba_def_seen[t] = true
					ba_def << t
				}
				i++
				continue
			}
			if t.starts_with('BA_ ') || t.starts_with('VAL_ ') || t.starts_with('CM_ BO_')
				|| t.starts_with('CM_ SG_') {
				vals << t
				i++
				continue
			}
			i++
		}
	}

	mut b := []string{}
	b << 'VERSION ""'
	b << ''
	b << 'NS_ :'
	b << ''
	b << 'BS_:'
	b << ''
	b << 'BU_: ${nodes.join(' ')}'
	b << ''
	for blk in blocks {
		b << blk
		b << ''
	}
	for d in ba_def {
		b << d
	}
	for v in vals {
		b << v
	}
	b << ''
	os.write_file(out, b.join('\n')) or {
		eprintln('dbcmerge: write ${out}: ${err}')
		exit(1)
	}
	println('dbcmerge: ${blocks.len} frame(s), ${nodes.len} node(s) -> ${out}')
}
