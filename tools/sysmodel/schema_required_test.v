module sysmodel

import os
import tools.cfgschema

// The system schema's `required` rows are pinned to what sysmodel REFUSES when the key is absent
// (the ecucheck rows were pinned the same way when specs() moved into the schema): each key of
// examples/system_full/system.toml is dropped in turn and the system validated as syscheck does.
// A key whose absence is refused must be a required row — or be listed below as CONDITIONAL, with
// the condition, which its description states too — and a required row must be refused. Every
// row is accounted for: dropped here, or named as absent from the fixture.

// conditional: refused when dropped from THIS fixture, because of a condition it meets
const conditional = {
	'sys_bus.interface':        "a gateway's NM bus is matched by interface"
	'sys_bus.kind':             'a bus with `service` must be someip'
	'sys_bus.dbc':              'a CAN bus carrying a [[signal]]'
	'sys_bus.service':          'kind = "someip"'
	'sys_bus.version':          'kind = "someip" in a dissolved system'
	'sys_bus_nm.peers':         'a member allocates an `nm` id'
	'sys_node.nm':              'a threadx member of an NM bus'
	'sys_node.diag':            'the node declares `doip`'
	'sys_endpoint.port':        'the node is on a someip bus'
	'sys_doip.allow_bench_key': 'the node uses [uds] security_key = "reference"'
	'sys_frame_e2e.timeout_ms': 'the event is not mode = "event"'
	'sys_node.endpoint':        'a member of a someip bus, or a DoIP entity'
	'sys_route.signal':         'exactly one of frame / signal'
}

// absent: rows the fixture does not exercise (no instance to drop)
const absent = ['sys_bus.bitrate', 'sys_bus_nm.repeat_ms', 'sys_bus_nm.wait_sleep_ms',
	'sys_doip.functional', 'sys_doip.activation_types', 'sys_doip.initial_inactivity_ms',
	'sys_doip.general_inactivity_ms', 'sys_doip.announce_count', 'sys_doip.announce_interval_ms',
	'sys_route.frame', 'sys_endpoint.netmask', 'sys_endpoint.gateway']

struct Drop {
	row  string // ctx.key
	find string
	repl string
}

// line: drop `key = …` from the first table under `header`
fn line(row string, header string, key string, text string) Drop {
	h := text.index('\n${header}\n') or { panic('fixture has no ${header}') }
	for l in text[h + 1..].split('\n')[1..] {
		if l.starts_with('[') {
			break
		}
		if l.starts_with('${key} ') || l.starts_with('${key}=') {
			return Drop{row, '${header}\n' + text[h + header.len + 2..].all_before(l) + l + '\n', '${header}\n' + text[h + header.len + 2..].all_before(l)}
		}
	}
	panic('fixture has no ${key} under ${header}')
}

fn fixture_dir() string {
	dir := os.join_path(os.temp_dir(), 'sysmodel_required_${os.getpid()}')
	src := os.join_path(@VMODROOT, 'examples', 'system_full')
	os.mkdir_all(dir) or { panic(err) }
	for f in os.ls(src) or { [] } {
		if f.ends_with('.dbc') {
			os.cp(os.join_path(src, f), os.join_path(dir, f)) or { panic(err) }
		}
	}
	for n in os.ls(os.join_path(src, 'nodes')) or { [] } {
		e := os.join_path(src, 'nodes', n, 'ecu.toml')
		if os.exists(e) {
			os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
			os.cp(e, os.join_path(dir, 'nodes', n, 'ecu.toml')) or { panic(err) }
		}
	}
	return dir
}

// refused: the errors syscheck reports for this system.toml text
fn refused(dir string, text string) []string {
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, text) or { panic(err) }
	mut s := parse_system(path) or { return [err.msg()] }
	dissolved := s.signals.len > 0 || s.routes.len > 0 || s.frames.len > 0 || s.nodes.any(it.has_endpoint)
	mut out := if dissolved { s.load_nodes_partial() } else { s.load_nodes() }
	issues := if dissolved { validate_system_gen(s) } else { validate_system(s) }
	for i in issues {
		if i.severity == .error {
			out << i.msg
		}
	}
	return out
}

fn test_a_required_row_is_exactly_a_key_sysmodel_refuses_to_miss() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	text := os.read_file(os.join_path(@VMODROOT, 'examples', 'system_full', 'system.toml')) or {
		panic(err)
	}
	assert refused(dir, text) == [], 'the fixture itself is refused'
	mut drops := []Drop{}
	for k in ['interface', 'fd', 'dbc'] {
		drops << line('sys_bus.${k}', '[bus.compute]', k, text)
	}
	for k in ['kind', 'service', 'version'] {
		drops << line('sys_bus.${k}', '[bus.tel]', k, text)
	}
	for k in ['peers', 'msg_cycle_ms', 'timeout_ms'] {
		drops << line('sys_bus_nm.${k}', '[bus.compute.nm]', k, text)
	}
	for k in ['name', 'fields', 'producer', 'bus', 'frame', 'cycle_ms'] {
		drops << line('sys_signal.${k}', '[[signal]]', k, text)
	}
	for k in ['name', 'ecu', 'buses', 'nm', 'trace', 'diag', 'endpoint', 'doip'] {
		drops << line('sys_node.${k}', '[[node]]', k, text)
	}
	for k in ['name', 'bus', 'id', 'signals', 'tx', 'e2e'] {
		drops << line('sys_frame.${k}', '[[frame]]', k, text)
	}
	for k in ['gateway', 'signal', 'from', 'to'] {
		drops << line('sys_route.${k}', '[[route]]', k, text)
	}
	// inline tables: the first node's endpoint / doip / diag, the first frame's tx / e2e
	drops << Drop{'sys_endpoint.address', 'endpoint = { address = "192.168.0.50", port', 'endpoint = { port'}
	drops << Drop{'sys_endpoint.port', 'address = "192.168.0.50", port = 30490 }', 'address = "192.168.0.50" }'}
	drops << Drop{'sys_doip.logical', 'doip     = { logical = 0x07A0, ', 'doip     = { '}
	drops << Drop{'sys_doip.testers', 'testers = [0x0E00], ', ''}
	drops << Drop{'sys_doip.allow_bench_key', ', allow_bench_key = true }', ' }'}
	drops << Drop{'sys_diag.req', 'diag     = { req = 0x7A0, rsp', 'diag     = { rsp'}
	drops << Drop{'sys_diag.rsp', 'req = 0x7A0, rsp = 0x7A8 }', 'req = 0x7A0 }'}
	drops << Drop{'sys_frame_tx.mode', 'tx      = { mode = "cyclic", cycle_ms = 300 }', 'tx      = { cycle_ms = 300 }'}
	drops << Drop{'sys_frame_tx.cycle_ms', 'tx      = { mode = "cyclic", cycle_ms = 300 }', 'tx      = { mode = "cyclic" }'}
	drops << Drop{'sys_frame_tx.min_delay_ms', 'tx      = { mode = "event", min_delay_ms = 30 }', 'tx      = { mode = "event" }'}
	drops << Drop{'sys_frame_e2e.data_id', 'e2e     = { data_id = 0x21, ', 'e2e     = { '}
	drops << Drop{'sys_frame_e2e.counter_pos', 'counter_pos = 7, ', ''}
	drops << Drop{'sys_frame_e2e.crc_pos', 'crc_pos = 8, ', ''}
	drops << Drop{'sys_frame_e2e.timeout_ms', 'crc_pos = 8, timeout_ms = 1000 }', 'crc_pos = 8 }'}

	mut seen := map[string]bool{}
	for d in drops {
		assert text.contains(d.find), '${d.row}: the fixture has no `${d.find}`'
		seen[d.row] = true
		ctx := d.row.all_before('.')
		row := cfgschema.system.key(ctx, d.row.all_after('.'))
		e := refused(dir, text.replace_once(d.find, d.repl))
		if row.required {
			assert e.len > 0, '${d.row} is a required row, but a system without it is accepted'
		} else if e.len > 0 {
			assert d.row in conditional, '${d.row}: its absence is refused (${e[0]}) — mark the row required, or list the condition'
		} else {
			assert d.row !in conditional, '${d.row} is listed conditional but its absence is accepted'
		}
	}
	// the sections themselves: a system with no bus or no node is not one
	assert cfgschema.system.key('sys_top', 'bus').required && cfgschema.system.key('sys_top', 'node').required
	e := check_topology_wellformed(System{}).map(it.msg)
	assert e.any(it.starts_with('no [bus.*] declared')) && e.any(it.starts_with('no [[node]] declared'))
	// every row is accounted for
	for t in cfgschema.system.tables {
		for k in t.keys {
			r := '${t.ctx}.${k.name}'
			if t.ctx == 'sys_top' || r == 'sys_bus.nm' {
				// sections, checked above (a bus's nm cluster is optional)
				continue
			}
			assert r in seen || r in absent, '${r} is neither dropped from the fixture nor listed absent'
			if r in absent {
				assert !k.required, '${r} is required but never exercised'
			}
		}
	}
}

// an endpoint's subnet keys are read from the file and judged there (tools/netcfg); the rows are
// optional, so their only test of absence is the fixture above, which has neither
fn test_an_endpoint_subnet_is_read_and_checked() {
	dir := fixture_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	text := os.read_file(os.join_path(@VMODROOT, 'examples', 'system_full', 'system.toml')) or {
		panic(err)
	}
	ep := 'endpoint = { address = "192.168.0.50", port = 30490 }'
	assert text.contains(ep)
	with := fn [text, ep] (keys string) string {
		return text.replace_once(ep, 'endpoint = { address = "192.168.0.50", port = 30490, ${keys} }')
	}
	good := with('netmask = "255.255.0.0", gateway = "192.168.3.1"')
	assert refused(dir, good) == []
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, good) or { panic(err) }
	s := parse_system(path) or { panic(err) }
	n := s.nodes.filter(it.name == 'sysnode')[0]
	assert n.endpoint_netmask or { '' } == '255.255.0.0'
	assert n.endpoint_gateway or { '' } == '192.168.3.1'
	for keys, want in {
		'netmask = "255.255.255.1"':  'not a contiguous mask'
		'netmask = 24':               'endpoint `netmask` must be a string'
		'gateway = "10.0.0.1"':       'gateway "10.0.0.1" is not on the subnet 192.168.0.0/255.255.255.0'
		'gateway = "192.168.0.0"':    'is the network address of'
		'gateway = "192.168.0.255"':  'is the broadcast address of'
		'gateway = "192.168.0.50"':   'is its own gateway'
	} {
		e := refused(dir, with(keys))
		assert e.any(it.contains(want)), '${keys}: ${e}'
	}
}
