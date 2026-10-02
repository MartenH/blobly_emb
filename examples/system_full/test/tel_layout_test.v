module main

// The tel segment's E2E command / status pair, as BOTH ends lower it from system.toml. An event's
// payload is laid out by ecumodel.eth_layouts — signals in list order, fields NAME-SORTED — so
// renaming a SafeStatus field moves its bytes. tcu_e2e.lua decodes BenchSafeStatus and builds
// BenchCmdSafe at fixed offsets; this pins those offsets to what the generator derives from the
// committed system.toml, so a rename fails here and not on the bench.
import os
import toml
import tools.ecumodel

const repo = os.real_path(os.join_path(os.dir(@FILE), '..', '..', '..'))

struct Cell {
	field  string
	offset int
	width  int
}

fn lowered(node string) []ecumodel.EthLayoutCell {
	out := os.join_path(os.vtmp_dir(), 'tel_layout_${os.getpid()}')
	os.mkdir_all(out) or { panic(err) }
	defer {
		os.rmdir_all(out) or {}
	}
	sysgen := os.join_path(repo, 'tools', 'sysgen')
	sys := os.join_path(repo, 'examples', 'system_full', 'system.toml')
	r := os.execute('${os.quoted_path(@VEXE)} -enable-globals run ${os.quoted_path(sysgen)} ${os.quoted_path(sys)} --out ${os.quoted_path(out)}')
	assert r.exit_code == 0, r.output
	doc := toml.parse_file(os.join_path(out, 'gen-${node}.toml')) or { panic(err) }
	return ecumodel.eth_layouts(doc)
}

fn cells(layout []ecumodel.EthLayoutCell, frame string) []Cell {
	return layout.filter(it.frame == frame).map(Cell{
		field:  it.field
		offset: it.offset
		width:  it.width
	})
}

// what tcu_e2e.lua reads: level byte 1, missed bytes 2..3 (LE), verdict byte 4 (Lua is 1-based)
const safe_status = [Cell{'level', 0, 1}, Cell{'missed', 1, 2}, Cell{'verdict', 3, 1}]
// what tcu_e2e.lua sends: level at 0, the E2E counter at 1 and CRC at 2 (system.toml's e2e)
const cmd_safe = [Cell{'level', 0, 1}]

fn test_both_ends_lower_the_layout_the_bench_decodes() {
	for node in ['tcu', 'tester'] {
		layout := lowered(node)
		assert cells(layout, 'BenchSafeStatus') == safe_status, '${node}: BenchSafeStatus'
		assert cells(layout, 'BenchCmdSafe') == cmd_safe, '${node}: BenchCmdSafe'
	}
}
