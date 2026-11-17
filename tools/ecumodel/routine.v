module ecumodel

import toml

// A [[routine]]'s two names in the [[fb]] handlers (docs/diagnostics.md §3.1): its `<Name>Request`,
// which the diagnostic server alone writes and exactly one handler reads (the one that runs it), and
// its `<Name>Result`, which that same handler alone writes and the server alone reads. The ONE
// statement of that rule and its wording, which loom2v refuses a node by at generation and sysmodel
// a system by (REQ-DIAG-087).

// routine_request / routine_result: the names a routine's FB reads and writes
pub fn routine_request(name string) string {
	return name + 'Request'
}

pub fn routine_result(name string) string {
	return name + 'Result'
}

// RoutineUse is where a routine's request and result appear in the [[fb]] handlers, each handler as
// "Fb.handler"
pub struct RoutineUse {
pub mut:
	req_readers []string
	req_writers []string
	res_readers []string
	res_writers []string
	period_ms   int // the request's reading handler's (the last one, when several read it)
}

// routine_names: every [[routine]]'s name, in declaration order — one with no name is left out,
// since the missing key is its refusal and it has no ports to name
pub fn routine_names(doc toml.Doc) []string {
	return toml_arr(doc, 'routine').map(str_of(it.as_map(), 'name')).filter(it != '')
}

// routine_use: where routine `name`'s request and result appear in the [[fb]] handlers
pub fn routine_use(doc toml.Doc, name string) RoutineUse {
	req := routine_request(name)
	res := routine_result(name)
	mut u := RoutineUse{}
	for c in toml_arr(doc, 'fb') {
		cm := c.as_map()
		fb := str_of(cm, 'name')
		for h in arr_of(cm, 'handler') {
			hm := h.as_map()
			at := '${fb}.${str_of(hm, 'name')}'
			reads := arr_of(hm, 'reads').map(it.string())
			writes := arr_of(hm, 'writes').map(it.string())
			if req in reads {
				u.req_readers << at
				u.period_ms = int((hm['period_ms'] or { toml.Any(0) }).int())
			}
			if req in writes {
				u.req_writers << at
			}
			if res in reads {
				u.res_readers << at
			}
			if res in writes {
				u.res_writers << at
			}
		}
	}
	return u
}

// routine_use_refusal: why routine `name`'s FB wiring cannot be generated — one handler reads the
// request and writes the result, and nothing else touches either — or none
pub fn routine_use_refusal(name string, u RoutineUse) ?string {
	h := '[[routine]] "${name}"'
	req := routine_request(name)
	res := routine_result(name)
	if u.req_readers.len != 1 {
		return '${h}: `${req}` must be read by exactly one FB handler (the one that runs it), not ${u.req_readers.len} ${u.req_readers} (REQ-DIAG-087)'
	}
	if u.req_writers.len > 0 {
		return "${h}: `${req}` is written by ${u.req_writers} — the diagnostic server alone writes a routine's request (REQ-DIAG-087)"
	}
	if u.res_writers != u.req_readers {
		return '${h}: `${res}` must be written by the handler that reads `${req}` (${u.req_readers[0]}) and by no other, not ${u.res_writers} (REQ-DIAG-087)'
	}
	if u.res_readers.len > 0 {
		return "${h}: `${res}` is read by ${u.res_readers} — the diagnostic server alone reads a routine's result (REQ-DIAG-087)"
	}
	return none
}

// routine_use_refusals: routine_use_refusal for every [[routine]] of the node
pub fn routine_use_refusals(doc toml.Doc) []string {
	mut out := []string{}
	for name in routine_names(doc) {
		if why := routine_use_refusal(name, routine_use(doc, name)) {
			out << why
		}
	}
	return out
}
