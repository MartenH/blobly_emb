module ecumodel

import toml

fn errs_of(text string) []string {
	doc := toml.parse_text(text) or { panic('bad test toml: ${err}') }
	return validate(doc)
}

// The structurally valid tail every fixture appends AFTER its bare tables — a single
// partition/thread + fb, the shape every example uses. (Bare tables must precede the
// array-of-tables blocks: V's TOML parser mis-parses a bare [table] that follows a
// [[array.of.tables]] — the same ordering the real ecu.toml files use.)
const app = '
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "app_main"

[[fb]]
name = "Work"
thread = "app_main"
  [[fb.handler]]
  name = "on_10ms"
  period_ms = 10
'

fn test_good_config_has_no_errors() {
	assert errs_of(app) == []
}

fn test_partition_needs_core_and_thread() {
	e := errs_of('
[[partition]]
name = "app"
')
	assert e.any(it.contains('missing `core`'))
	assert e.any(it.contains('no [[partition.thread]]'))
}

fn test_thread_names_globally_unique() {
	e := errs_of('
[[partition]]
name = "a"
core = 0
  [[partition.thread]]
  name = "main"
[[partition]]
name = "b"
core = 1
  [[partition.thread]]
  name = "main"
')
	assert e.any(it.contains('duplicate thread name "main"'))
}

fn test_fb_thread_must_resolve_and_needs_handler() {
	e := errs_of('
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "app_main"
[[fb]]
name = "Work"
thread = "ghost"
')
	assert e.any(it.contains('unknown thread "ghost"'))
	assert e.any(it.contains('no [[fb.handler]]'))
}

fn test_irq_handler_is_reserved() {
	e := errs_of('
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "app_main"
[[fb]]
name = "Work"
thread = "app_main"
  [[fb.handler]]
  name = "on_irq"
  irq = 42
')
	assert e.any(it.contains('irq-triggered handlers are not generated yet'))
}

// --- [trace] block validation (bare tables first, then the app tail) ---

fn test_trace_valid_block_ok() {
	assert errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
level = "thread+fb"
mode = "ring"
pre_pct = 50
buffer_records = 64
' + app) == []
}

fn test_trace_unknown_bus_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can9"
' + app)
	assert e.any(it.contains('[trace] names unknown bus "can9"'))
}

fn test_trace_bad_level_and_mode_flagged() {
	e := errs_of('
[trace]
level = "everything"
mode = "circular"
' + app)
	assert e.any(it.contains('level "everything" is invalid'))
	assert e.any(it.contains('mode "circular" is invalid'))
}

fn test_trace_pre_pct_and_buffer_range_flagged() {
	e := errs_of('
[trace]
pre_pct = 150
buffer_records = 0
' + app)
	assert e.any(it.contains('pre_pct 150 out of range'))
	assert e.any(it.contains('buffer_records 0 must be > 0'))
}

// absent [trace] must not synthesize errors (it's optional).
fn test_no_trace_block_is_fine() {
	assert errs_of(app) == []
}
