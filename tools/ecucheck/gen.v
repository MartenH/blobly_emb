// ecucheck — BUILD-TIME schema validator for ecu.toml. V's `toml` lib validates syntax
// but knows nothing about OUR schema, so a misspelled or unknown key (`partiton`,
// `period_ns`) is silently ignored and surfaces later as a baffling codegen failure or
// wrong behaviour. ecucheck walks the parsed config against a declared schema — allowed
// keys (with "did you mean" for typos), required keys, and types — the schema is tools/cfgschema,
// shared with the reference doc and the editors' JSON Schema — and enforces the
// cross-field rules (unique names, fb->thread resolves, one trigger per handler). It runs
// BEFORE the generators (cfg2v/loom2v/sigmap all parse the same file), reporting EVERY
// problem at once, so no generator ever sees an invalid config.
//
//   v run tools/ecucheck/gen.v <ecu.toml>
module main

import os
import toml
import tools.ecumodel
import tools.cfgschema

fn main() {
	if os.args.len < 2 {
		eprintln('usage: ecucheck <ecu.toml>')
		exit(2)
	}
	path := os.args[1]
	doc := toml.parse_file(path) or {
		eprintln('ecucheck: parse ${path}: ${err}')
		exit(1)
	}
	mut errs := []string{}
	check_raw(os.read_file(path) or { '' }, mut errs)
	// unknown keys, types, required keys: the ONE schema (tools/cfgschema)
	errs << cfgschema.ecu.check(doc.to_any().as_map())
	// the partition/thread/fb structural rules live in ecumodel, shared with loom2v so the
	// gate and the generator can't drift.
	errs << ecumodel.validate(doc)
	fname := os.file_name(path)
	if errs.len > 0 {
		for e in errs {
			eprintln('${fname}: ${e}')
		}
		eprintln('ecucheck: ${errs.len} schema error(s) in ${fname}')
		exit(1)
	}
	eprintln('ecucheck: ${fname} ok')
}

// check_raw is a LEXICAL pass (independent of the buggy parser): V's TOML parser silently
// drops the key following a comment inside a nested `[[a.b]]` array-of-tables block
// (verified on `[[partition.thread]]` / `[[fb.handler]]`). The dropped key is invisible to
// the parse-based checks when it's optional, so scan the raw text and forbid comments inside
// such blocks outright.
fn check_raw(text string, mut errs []string) {
	lines := text.split_into_lines()
	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		// a nested [[a.b]] block: scan its body (until the next table header) and flag it if a
		// comment appears BEFORE a later key — that later key is what the parser drops. A
		// comment after the block's last key (before the next header) is harmless.
		if line.starts_with('[[') && line.contains('.') {
			mut j := i + 1
			mut comment_at := -1
			mut last_key := -1
			mut depth := 0 // open '[' of a multi-line array value; its continuation lines aren't keys
			for j < lines.len {
				l := lines[j].trim_space()
				if depth == 0 && l.starts_with('[') {
					break // the next table header
				}
				if l != '' && depth == 0 {
					if has_comment(l) && comment_at < 0 {
						comment_at = j
					}
					if !l.starts_with('#') {
						last_key = j
					}
				}
				depth += bracket_delta(l) // enter/leave a multi-line reads/writes array
				if depth < 0 {
					depth = 0
				}
				j++
			}
			if comment_at >= 0 && last_key > comment_at {
				errs << 'line ${comment_at + 1}: comment inside ${line} drops the following key ' +
					'(a V TOML parser bug) — keep [[a.b]] blocks comment-free, move the note above the block'
			}
			i = j
			continue
		}
		i++
	}
}

// bracket_delta counts '[' minus ']' outside strings and comments — to track multi-line arrays
// (a `reads = [` that closes on a later line) so their element lines aren't mistaken for keys.
fn bracket_delta(line string) int {
	mut d := 0
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `"` {
			i++
			for i < line.len && line[i] != `"` {
				if line[i] == `\\` {
					i++
				}
				i++
			}
		} else if c == `'` {
			i++
			for i < line.len && line[i] != `'` {
				i++
			}
		} else if c == `#` {
			break // comment: ignore the rest of the line
		} else if c == `[` {
			d++
		} else if c == `]` {
			d--
		}
		i++
	}
	return d
}

// has_comment reports whether the line has a `#` comment outside a quoted string. Honors both
// basic (`"`, with `\"` escapes) and literal (`'`) TOML strings so a `#` inside a value isn't
// mistaken for a comment (and an escaped quote doesn't leak the "in string" state).
fn has_comment(line string) bool {
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `"` {
			i++
			for i < line.len && line[i] != `"` {
				if line[i] == `\\` {
					i++
				}
				i++
			}
		} else if c == `'` {
			i++
			for i < line.len && line[i] != `'` {
				i++
			}
		} else if c == `#` {
			return true
		}
		i++
	}
	return false
}
