module ecumodel

import toml

// The naming rule, config name -> generated identifier (docs/um/fb-programming-model.md
// "Names"). Every generator that turns a name into an identifier calls snake_name, and every
// scope those identifiers land in is checked with a SnakeScope, so what the validator refuses
// and what a generator emits cannot drift apart.

// snake_name is THE snake-case normalization generated identifiers use. A capital starts a
// word after a lowercase letter or a digit, and an acronym is a word of its own: the last
// capital of a run starts the next word when a lowercase letter follows it, so `ABSActive` ->
// `abs_active` and `LED5State` -> `led5_state`. Any other character becomes `_`.
pub fn snake_name(name string) string {
	mut out := []u8{}
	for i, c in name {
		is_upper := c >= `A` && c <= `Z`
		if is_upper && i > 0 {
			prev := name[i - 1]
			next_lower := i + 1 < name.len && name[i + 1] >= `a` && name[i + 1] <= `z`
			if (prev >= `a` && prev <= `z`) || (prev >= `0` && prev <= `9`)
				|| (prev >= `A` && prev <= `Z` && next_lower) {
				out << `_`
			}
		}
		if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) {
			out << c
		} else if is_upper {
			out << c + 32
		} else {
			out << `_`
		}
	}
	return out.bytestr()
}

// pascal_ok reports whether s is PascalCase — [A-Z][A-Za-z0-9]* — the one spelling a name we
// own may take in config (an FB, an internal signal, a fault). With no `_` allowed, two
// spellings of one name (`EngineOverRev`, `Engine_Over_Rev`) cannot both exist. Names a DBC
// owns (bus signals and frames) are exempt: they are the bus owner's, not ours.
pub fn pascal_ok(s string) bool {
	if s == '' || !(s[0] >= `A` && s[0] <= `Z`) {
		return false
	}
	for c in s {
		if !((c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)) {
			return false
		}
	}
	return true
}

// SnakeScope is one generated namespace (the signals, the FBs, one FB's faults, one DBC's
// frames, ...). add refuses a name whose identifier is already taken there — an exact repeat,
// or a different spelling that snakes to the same identifier (`AbsActive` / `ABSActive`).
pub struct SnakeScope {
	what string // the kind, for the message: 'signal', 'fb', 'fault of Brake', ...
mut:
	seen map[string]string // identifier -> the name that took it
}

pub fn snake_scope(what string) SnakeScope {
	return SnakeScope{
		what: what
	}
}

// add takes name's identifier, or returns the error when it is already taken (none = free).
pub fn (mut s SnakeScope) add(name string) ?string {
	id := snake_name(name)
	if prev := s.seen[id] {
		if prev == name {
			return 'duplicate ${s.what} "${name}"'
		}
		return '${s.what} "${name}" collides with "${prev}": both generate `${id}`'
	}
	s.seen[id] = name
	return none
}

// validate_signal_names: every [[signal]] has a name that is an identifier, unique in the
// signal scope after snake-casing; a signal no bus carries is ours, so it is also PascalCase. A
// signal a bus carries is named by the DBC (the signal-name contract, docs/ways-of-working.md),
// so it gets the scope check but not the spelling rule.
fn validate_signal_names(doc toml.Doc, bus_names map[string]bool) []string {
	mut errs := []string{}
	mut scope := snake_scope('signal')
	for sg in toml_arr(doc, 'signal') {
		sm := sg.as_map()
		name := str_of(sm, 'name')
		if 'name' !in sm {
			errs << 'a [[signal]] is missing `name`'
			continue
		}
		on_bus := str_of(sm, 'from') in bus_names || str_of(sm, 'to') in bus_names
		if on_bus && !ident_ok(name) {
			errs << 'signal name "${name}" is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)'
			continue
		}
		if !on_bus && !pascal_ok(name) {
			errs << 'signal name "${name}" is not PascalCase ([A-Z][A-Za-z0-9]*) — a signal no bus carries is named here, in the one spelling'
			continue
		}
		if e := scope.add(name) {
			errs << e
		}
	}
	return errs
}
