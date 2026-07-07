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
	assert e.any(it.contains('[trace] bus "can9"') && it.contains('not a declared'))
}

// when trace omits `bus`, the default [telemetry].bus is validated too (must be declared).
fn test_trace_default_telemetry_bus_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[telemetry]
enabled = true
bus = "can9"

[trace]
level = "thread"
' + app)
	assert e.any(it.contains('[trace] bus "can9"') && it.contains('[telemetry].bus'))
}

// with neither trace.bus nor a telemetry bus there is no channel to bind to.
fn test_trace_no_bus_at_all_flagged() {
	e := errs_of('
[trace]
level = "thread"
' + app)
	assert e.any(it.contains('[trace] has no bus'))
}

fn test_trace_bad_level_and_mode_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
level = "everything"
mode = "circular"
' + app)
	assert e.any(it.contains('level "everything" is invalid'))
	assert e.any(it.contains('mode "circular" is invalid'))
}

fn test_trace_pre_pct_and_buffer_range_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
pre_pct = 150
buffer_records = 70000
' + app)
	assert e.any(it.contains('pre_pct 150 out of range'))
	assert e.any(it.contains('buffer_records 70000 out of range'))
}

// a frame id reused across trace frames (or out of CAN range) must be rejected.
fn test_trace_duplicate_and_out_of_range_ids_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
rsp_id = 0x7E2
cmd_id = 0x7E2
stat_id = -1
' + app)
	assert e.any(it.contains('used by both') && it.contains('cmd_id'))
	assert e.any(it.contains('stat_id') && it.contains('out of CAN id range'))
}

// an out-of-range telemetry detail_id must be caught before it reaches the generated trace DBC.
fn test_trace_telemetry_detail_id_out_of_range_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[telemetry]
enabled = true
bus = "can0"
id = 0x7E0
detail_id = -1

[trace]
bus = "can0"
' + app)
	assert e.any(it.contains('telemetry.detail_id') && it.contains('out of CAN id range'))
}

// a trace id colliding with an enabled telemetry frame on the SAME bus is a wire collision.
fn test_trace_id_collides_with_telemetry_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[telemetry]
enabled = true
bus = "can0"
id = 0x7E2

[trace]
bus = "can0"
' + app)
	assert e.any(it.contains('used by both') && it.contains('telemetry.id'))
}

// the same id reused by telemetry on a DIFFERENT bus can't collide on the wire — don't flag it.
fn test_trace_id_reused_by_telemetry_on_other_bus_ok() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[bus.can1]
interface = "vcan1"

[telemetry]
enabled = true
bus = "can0"
id = 0x7E2

[trace]
bus = "can1"
' + app)
	assert e.filter(it.contains('used by both')).len == 0
}

// absent [trace] must not synthesize errors (it's optional).
fn test_no_trace_block_is_fine() {
	assert errs_of(app) == []
}
