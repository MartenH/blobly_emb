module main

// blank_unused_params renames to `_` every parameter a generated function never reads, so the
// emitted V compiles without V's "unused parameter" notice. The emitters write callbacks to fixed
// signatures (a shell command, a trace hook, a FlashOps or a Store entry) whose bodies use only
// some of what the seam passes; the signature cannot change, the name can. Functions are the
// generators' shape: `fn` at column 0, the body up to the next `}` at column 0 (or `{}` on the
// line). A `mut` parameter keeps its name: `mut _` is not V, and the mutability is part of the
// callback's type.
fn blank_unused_params(lines []string) []string {
	mut out := lines.clone()
	mut i := 0
	for i < out.len {
		l := out[i]
		is_fn := (l.starts_with('fn ') || l.starts_with('pub fn ')) && !l.contains('fn C.')
		if !is_fn || !l.trim_right(' ').ends_with('{') {
			if is_fn && l.trim_right(' ').ends_with('{}') {
				out[i] = blank_in_signature(l, '')
			}
			i++
			continue
		}
		mut end := i + 1
		for end < out.len && out[end] != '}' {
			end++
		}
		out[i] = blank_in_signature(l, out[i + 1..end].join('\n'))
		i = end + 1
	}
	return out
}

// blank_in_signature: `sig` (one `fn ...(...)` line) with each parameter `body` never names as `_`
fn blank_in_signature(sig string, body string) string {
	// the parameter list: the first parenthesised group, or the second for a method
	mut open := sig.index_u8(`(`)
	if sig.starts_with('fn (') || sig.starts_with('pub fn (') {
		open = sig.index_after('(', closing_paren(sig, open) + 1) or { return sig }
	}
	if open < 0 {
		return sig
	}
	close := closing_paren(sig, open)
	if close < 0 {
		return sig
	}
	mut params := split_params(sig[open + 1..close])
	mut changed := false
	for mut p in params {
		name := p.all_before(' ')
		if name == '' || name == '_' || name == 'mut' || !p.contains(' ') || mentions_ident(body, name) {
			continue
		}
		p = '_' + p[name.len..]
		changed = true
	}
	if !changed {
		return sig
	}
	return sig[..open + 1] + params.join(', ') + sig[close..]
}

// closing_paren: the index of the `)` that closes the `(` at `open`, or -1
fn closing_paren(s string, open int) int {
	mut depth := 0
	for j in open .. s.len {
		if s[j] == `(` {
			depth++
		} else if s[j] == `)` {
			depth--
			if depth == 0 {
				return j
			}
		}
	}
	return -1
}

// split_params: a parameter list split at its top-level commas (a type may be `fn (a, b)`)
fn split_params(s string) []string {
	mut out := []string{}
	mut depth := 0
	mut start := 0
	for j in 0 .. s.len {
		match s[j] {
			`(`, `[` { depth++ }
			`)`, `]` { depth-- }
			`,` {
				if depth == 0 {
					out << s[start..j].trim_space()
					start = j + 1
				}
			}
			else {}
		}
	}
	if s.trim_space() != '' {
		out << s[start..].trim_space()
	}
	return out
}

// mentions_ident: `text` contains `name` as a whole identifier
fn mentions_ident(text string, name string) bool {
	mut from := 0
	for {
		at := text.index_after(name, from) or { return false }
		before := at == 0 || !is_ident_byte(text[at - 1])
		after := at + name.len >= text.len || !is_ident_byte(text[at + name.len])
		if before && after {
			return true
		}
		from = at + 1
	}
	return false
}

fn is_ident_byte(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}
