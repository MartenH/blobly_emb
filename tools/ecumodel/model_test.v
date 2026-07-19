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

// absent [trace] must not synthesize errors (it's optional).
fn test_no_trace_block_is_fine() {
	assert errs_of(app) == []
}

// enabled = false turns tracing off without deleting the block — no bus/ids validated.
fn test_trace_disabled_skips_validation() {
	assert errs_of('
[trace]
enabled = false
level = "bogus"
' + app) == []
}

// buffer_records lower bound.
fn test_trace_buffer_records_zero_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
buffer_records = 0
' + app)
	assert e.any(it.contains('buffer_records 0 out of range'))
}

// buffer_records above 2^32 must be rejected — .int() would truncate 0x100000001 back to 1.
fn test_trace_buffer_records_above_u32_flagged() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
buffer_records = 0x100000001
' + app)
	assert e.any(it.contains('buffer_records') && it.contains('out of range'))
}

// an "overrun" trigger with no positive budget_us never freezes the ring -> reject it.
fn test_trace_overrun_trigger_needs_budget() {
	no_budget := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "overrun" }
' + app)
	assert no_budget.any(it.contains('positive budget_us'))

	zero_budget := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "overrun", budget_us = 0 }
' + app)
	assert zero_budget.any(it.contains('positive budget_us'))

	ok := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "overrun", budget_us = 500 }
' + app)
	assert ok.filter(it.contains('budget_us')).len == 0
}

// an unsupported/misspelled trigger source is rejected (only "overrun" is generated).
fn test_trace_unsupported_trigger_source() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "signal" }
' + app)
	assert e.any(it.contains('trigger source "signal" is not supported'))
}

// a trigger table present but with no source is rejected (omit it entirely for no trigger).
fn test_trace_trigger_without_source() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { budget_us = 500 }
' + app)
	assert e.any(it.contains('trigger table has no source'))
}

// negative push_ms would wrap to a huge u64 interval -> reject it.
fn test_trace_negative_push_ms() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
push_ms = -1
' + app)
	assert e.any(it.contains('push_ms') && it.contains('must be >= 0'))
}

// ---- [io] rules (docs/io.md P1) ----

// a valid single-point io config: button input read by the app handler
const io_ok = '
[io]
core = 0
[[io.gpio]]
name      = "UserButton"
pin       = "PC13"
period_ms = 10

[[signal]]
name = "UserButton"
fields = { pressed = "bool" }
from = "io"
to   = "app"

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
  reads = ["UserButton"]
'

fn test_io_good_config_passes() {
	assert errs_of(io_ok) == []
}

fn test_io_reserved_endpoint_name() {
	e := errs_of('
[[partition]]
name = "io"
core = 0
  [[partition.thread]]
  name = "t"
')
	assert e.any(it.contains('reserved endpoint name'))
}

fn test_io_point_without_signal_rejected() {
	e := errs_of('
[io]
[[io.gpio]]
name      = "Ghost"
pin       = "PA0"
period_ms = 10
' + app)
	assert e.any(it.contains('no [[signal]] of that name'))
}

fn test_io_signal_without_point_rejected() {
	e := errs_of('
[io]
[[io.gpio]]
name      = "UserButton"
pin       = "PC13"
period_ms = 10

[[signal]]
name = "UserButton"
fields = { pressed = "bool" }
from = "io"
to   = "app"

[[signal]]
name = "Orphan"
fields = { on = "bool" }
from = "io"
to   = "app"
' + app)
	assert e.any(it.contains('phantom endpoint'))
}

// an io-bound signal with NO [io] table at all is still a phantom endpoint —
// the reverse one-to-one check must not be skipped by the missing table
fn test_io_signal_without_io_table_rejected() {
	e := errs_of('
[[signal]]
name = "Orphan"
fields = { on = "bool" }
from = "io"
to   = "app"
' + app)
	assert e.any(it.contains('phantom endpoint'))
}

// the driver backend holds at most 32 points (BLOB_IO_MAX)
fn test_io_too_many_points_rejected() {
	mut cfg := '[io]\n'
	mut sigs := ''
	for i in 0 .. 33 {
		cfg += '[[io.gpio]]\nname = "P${i}"\npin = "PA${i}"\nperiod_ms = 10\n\n'
		sigs += '[[signal]]\nname = "P${i}"\nfields = { on = "bool" }\nfrom = "io"\nto   = "app"\n\n'
	}
	e := errs_of(cfg + sigs + app)
	assert e.any(it.contains('at most 32'))
}

// the driver name buffer is 64 bytes — a longer name would silently truncate
// (two prefix-sharing names would collide on one mirror file)
fn test_io_overlong_name_rejected() {
	long := 'P' + 'x'.repeat(63)
	e := errs_of('
[io]
[[io.gpio]]
name      = "${long}"
pin       = "PC13"
period_ms = 10

[[signal]]
name = "${long}"
fields = { pressed = "bool" }
from = "io"
to   = "app"
' + app)
	assert e.any(it.contains('at most 63'))
}

fn test_io_output_needs_init_and_one_writer() {
	e := errs_of('
[io]
[[io.gpio]]
name      = "Led"
pin       = "PB0"
period_ms = 10

[[signal]]
name = "Led"
fields = { on = "bool" }
from = "app"
to   = "io"
' + app)
	assert e.any(it.contains('must declare init'))
	assert e.any(it.contains('exactly one writing handler'))
}

// default is the INPUT pre-first-sample port value — an output has init instead
fn test_io_output_rejects_default() {
	e := errs_of('
[io]
[[io.gpio]]
name      = "Led"
pin       = "PB0"
period_ms = 10
init      = false
default   = false

[[signal]]
name = "Led"
fields = { on = "bool" }
from = "app"
to   = "io"
' + app)
	assert e.any(it.contains('default is an input'))
}

fn test_io_rejects_bus_to_pin_and_explicit_transport() {
	e := errs_of('
[bus.can0]
interface = "vcan0"

[io]
[[io.gpio]]
name      = "Led"
pin       = "PB0"
period_ms = 10
init      = false

[[signal]]
name = "Led"
fields = { on = "bool" }
from = "can0"
to   = "io"
transport = "double"
' + app)
	assert e.any(it.contains('never bus-to-pin'))
	assert e.any(it.contains('transport is derived'))
}

fn test_io_pin_exclusive_and_harmonic_periods() {
	e := errs_of('
[io]
[[io.gpio]]
name      = "A"
pin       = "PB0"
period_ms = 7

[[io.gpio]]
name      = "B"
pin       = "PB0"
period_ms = 10

[[signal]]
name = "A"
fields = { on = "bool" }
from = "io"
to   = "app"

[[signal]]
name = "B"
fields = { on = "bool" }
from = "io"
to   = "app"
' + app)
	assert e.any(it.contains('one physical pad'))
	assert e.any(it.contains('not a multiple of the fastest'))
}

fn test_io_shape_must_be_single_bool() {
	e := errs_of('
[io]
[[io.gpio]]
name      = "Btn"
pin       = "PC13"
period_ms = 10

[[signal]]
name = "Btn"
fields = { level = "u16" }
from = "io"
to   = "app"
' + app)
	assert e.any(it.contains('carries a bool field'))
}

fn test_io_direction_mirror_rules() {
	// an FB writing an INPUT (double producer) and reading an OUTPUT
	// (double consumer of a single-reader channel) are both rejected
	e := errs_of('
[io]
[[io.gpio]]
name      = "Btn"
pin       = "PC13"
period_ms = 10

[[io.gpio]]
name      = "Led"
pin       = "PB0"
period_ms = 10
init      = false

[[signal]]
name = "Btn"
fields = { on = "bool" }
from = "io"
to   = "app"

[[signal]]
name = "Led"
fields = { on = "bool" }
from = "app"
to   = "io"

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
  reads = ["Btn", "Led"]
  writes = ["Led", "Btn"]
')
	assert e.any(it.contains('io thread is its only producer'))
	assert e.any(it.contains('io thread owns that channel side'))
}

fn test_io_accessor_partition_must_match_endpoint() {
	// the writer lives in "worker" but the signal declares "app"
	e := errs_of('
[io]
[[io.gpio]]
name      = "Led"
pin       = "PB0"
period_ms = 10
init      = false

[[signal]]
name = "Led"
fields = { on = "bool" }
from = "app"
to   = "io"

[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "app_main"

[[partition]]
name = "worker"
core = 0
  [[partition.thread]]
  name = "w_main"

[[fb]]
name = "Work"
thread = "w_main"
  [[fb.handler]]
  name = "on_10ms"
  period_ms = 10
  writes = ["Led"]
')
	assert e.any(it.contains('must live in the declared partition'))
}
