// cfgdoc — writes what tools/cfgschema generates: docs/config-reference.md and the JSON Schemas
// under schema/ that .taplo.toml maps ecu.toml, system.toml and gen-*.toml to. `--check` writes
// nothing and exits 1 naming every file that differs from what the schema generates (the
// freshness gate `make check` runs).
//
//   cfgdoc [--check] [<repo root>]
module main

import os
import tools.cfgschema

fn outputs() map[string]string {
	return {
		'docs/config-reference.md':  cfgschema.markdown([cfgschema.ecu, cfgschema.system])
		'schema/ecu.schema.json':    cfgschema.ecu.json_schema()
		'schema/system.schema.json': cfgschema.system.json_schema()
	}
}

fn main() {
	mut check := false
	mut root := '.'
	for a in os.args[1..] {
		if a == '--check' {
			check = true
		} else if a.starts_with('-') {
			eprintln('usage: cfgdoc [--check] [<repo root>]')
			exit(2)
		} else {
			root = a
		}
	}
	mut stale := []string{}
	for rel, want in outputs() {
		path := os.join_path(root, rel)
		if check {
			have := os.read_file(path) or { '' }
			if have != want {
				stale << rel
			}
			continue
		}
		os.mkdir_all(os.dir(path)) or {
			eprintln('cfgdoc: ${err}')
			exit(1)
		}
		os.write_file(path, want) or {
			eprintln('cfgdoc: write ${path}: ${err}')
			exit(1)
		}
	}
	if stale.len > 0 {
		for s in stale {
			eprintln('cfgdoc: ${s} is stale — run `make config-docs` and commit it')
		}
		exit(1)
	}
	if check {
		eprintln('cfgdoc: config reference and JSON Schemas are fresh')
	}
}
