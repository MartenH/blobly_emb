module main

fn rel_of(abs string) string {
	return if abs.starts_with('/r/') { abs[3..] } else { '' }
}

// two builds instrument one file with different point lists; a point is matched by its line
fn test_lines_union_across_builds_and_own_is_the_files_directory() {
	ms := [
		Meta{
			file:          '/r/comm/x/x.v'
			fhash:         'a'
			build_options: '-coverage d -o t /r/comm/x/x_test.v'
			points:        [10, 20, 30]
		},
		Meta{
			file:          '/r/comm/x/x.v'
			fhash:         'b'
			build_options: '-coverage d -o t /r/comm/y/y_test.v'
			points:        [20, 30, 40]
		},
		Meta{
			file:          '/vlib/builtin.v'
			fhash:         'c'
			build_options: '-o t /r/comm/x/x_test.v'
			points:        [1]
		},
	]
	hit := {
		'a': {
			0: true
		}
		'b': {
			0: true
			2: true
		}
		'c': {
			0: true
		}
	}
	got := attribute(ms, hit, rel_of)
	assert got.len == 1
	c := got['comm/x/x.v']
	assert c.points == 4 // lines 10, 20, 30, 40
	assert c.own == 1 // line 10, by x_test.v
	assert c.any == 3 // 10 by its own test, 20 and 40 by y_test.v
}

fn test_render_reads_back_and_a_drop_is_named() {
	before := [
		Cov{
			file:   'comm/x/x.v'
			points: 3
			own:    2
			any:    3
			built:  true
		},
		Cov{
			file: 'osal/osal.v'
		},
	]
	rec := parse_recorded(render(before))
	assert rec['comm/x/x.v'] == 66.7
	assert rec['osal/osal.v'] == -1.0
	assert drops(rec, before) == []
	mut after := before.clone()
	after[0] = Cov{
		...before[0]
		own: 1
	}
	assert drops(rec, after) == ['comm/x/x.v: 66.7% -> 33.3% (own tests)']
	after[0] = Cov{
		file: 'comm/x/x.v'
	}
	assert drops(rec, after) == ['comm/x/x.v: 66.7% -> not built by any host test']
}
