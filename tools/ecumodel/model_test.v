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
	assert errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
level = "thread+fb"
mode = "ring"
pre_pct = 50
buffer_records = 64
' +
		app) == []
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
	e := errs_of(
		'
[bus.can0]
interface = "vcan0"

[telemetry]
enabled = true
bus = "can9"

[trace]
level = "thread"
' +
		app)
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
	e := errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
level = "everything"
mode = "circular"
' +
		app)
	assert e.any(it.contains('level "everything" is invalid'))
	assert e.any(it.contains('mode "circular" is invalid'))
}

fn test_trace_pre_pct_and_buffer_range_flagged() {
	e := errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
pre_pct = 150
buffer_records = 70000
' +
		app)
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
	e := errs_of(
		'
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
	no_budget := errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "overrun" }
' +
		app)
	assert no_budget.any(it.contains('positive budget_us'))

	zero_budget := errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "overrun", budget_us = 0 }
' +
		app)
	assert zero_budget.any(it.contains('positive budget_us'))

	ok := errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "overrun", budget_us = 500 }
' +
		app)
	assert ok.filter(it.contains('budget_us')).len == 0
}

// an unsupported/misspelled trigger source is rejected (only "overrun" is generated).
fn test_trace_unsupported_trigger_source() {
	e := errs_of(
		'
[bus.can0]
interface = "vcan0"

[trace]
bus = "can0"
trigger = { source = "signal" }
' +
		app)
	assert e.any(it.contains('trigger source "signal" is not supported'))
}

// a trigger table present but with no source is rejected (omit it entirely for no trigger).
fn test_trace_trigger_without_source() {
	e := errs_of(
		'
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
	e := errs_of(
		'
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
' +
		app)
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
' +
		app)
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
	e := errs_of(
		'
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
' +
		app)
	assert e.any(it.contains('at most 63'))
}

fn test_io_output_needs_init_and_one_writer() {
	e := errs_of(
		'
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
' +
		app)
	assert e.any(it.contains('must declare init'))
	assert e.any(it.contains('exactly one writing handler'))
}

// default is the INPUT pre-first-sample port value — an output has init instead
fn test_io_output_rejects_default() {
	e := errs_of(
		'
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
' +
		app)
	assert e.any(it.contains('default is an input'))
}

fn test_io_rejects_bus_to_pin_and_explicit_transport() {
	e := errs_of(
		'
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
' +
		app)
	assert e.any(it.contains('never bus-to-pin'))
	assert e.any(it.contains('transport is derived'))
}

fn test_io_pin_exclusive_and_harmonic_periods() {
	e := errs_of(
		'
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
' +
		app)
	assert e.any(it.contains('one physical pad'))
	assert e.any(it.contains('not a multiple of the fastest'))
}

// pin exclusivity is keyed on the PARSED pad, and non-canonical spellings are
// rejected outright — "PB00" may not slip past raw-string uniqueness as a second
// spelling of "PB0" (the driver parses port letter + int)
fn test_io_pin_exclusivity_is_backend_neutral() {
	// pin GRAMMAR lives below the driver boundary (io_stm32.c rejects "PB00" at
	// cfg, so one pad has one spelling); the model checks only string-level
	// exclusivity — backend-neutral, per AGENTS.md (codex on emb#150 r4).
	e := errs_of('
[io]
[[io.gpio]]
name      = "A"
pin       = "PB0"
period_ms = 10

[[io.gpio]]
name      = "B"
pin       = "PB0"
period_ms = 10
')
	assert e.any(it.contains('reuses pad "PB0"'))
}

fn test_io_shape_must_be_single_bool() {
	e := errs_of(
		'
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
' +
		app)
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

// a [[did]] bound to an io signal would generate a second ioc_acquire on the
// single-reader channel — samples stolen from the app consumer
fn test_io_did_on_io_signal_rejected() {
	e := errs_of(io_ok + '
[[did]]
id     = 0xF101
signal = "UserButton"
')
	assert e.any(it.contains('second reader on a single-reader channel'))
	// a did on a NON-io signal stays legal
	ok := errs_of(io_ok +
		'
[[signal]]
name = "Speed"
fields = { kmh = "u16" }
from = "app"
to   = "app"

[[did]]
id     = 0xF102
signal = "Speed"
')
	assert ok.filter(it.contains('single-reader channel')).len == 0
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

fn test_io_rejects_input_init_and_cross_core() {
	e := errs_of('
[io]
core = 0
[[io.gpio]]
name      = "Btn"
pin       = "PC13"
period_ms = 10
init      = true

[[signal]]
name = "Btn"
fields = { on = "bool" }
from = "io"
to   = "far"

[[partition]]
name = "far"
core = 1
  [[partition.thread]]
  name = "far_main"

[[fb]]
name = "W"
thread = "far_main"
  [[fb.handler]]
  name = "on_10ms"
  period_ms = 10
  reads = ["Btn"]
')
	assert e.any(it.contains('init belongs to outputs'))
	assert e.any(it.contains('cross-core io arrives with the target phase'))
}

// ---- [someip] / eth bus rules (docs/someip.md) ------------------------------
// Groundwork for REQ-NET-017, deliberately left untagged for trace: the
// requirement also demands enforcement on RECEPTION (the source filter), which
// arrives with the rx rung; config-time fixing alone does not verify it.

// bare tables ([bus.eth0], [someip]) must precede the array-of-tables blocks —
// the same ordering rule the real ecu.toml files follow.
const eth_head = '
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"
core      = 0

[someip]
bus     = "eth0"
service = 0x0100
version = 1
port    = 30490
peer    = "192.168.0.10:30490"
'

const eth_tx_frame = '
[[signal]]
name = "CpuLoad"
fields = { load = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "BenchTelem"
bus     = "eth0"
id      = 0x8001
signals = ["CpuLoad"]

[[fb]]
name   = "CpuWriter"
thread = "app_main"
  [[fb.handler]]
  name      = "on_100ms"
  period_ms = 100
  writes    = ["CpuLoad"]
'

fn test_someip_good_config_has_no_errors() {
	assert errs_of(eth_head + eth_tx_frame + app) == []
}

fn test_someip_one_eth_bus_per_image() {
	e := errs_of(
		'
[bus.eth0]
kind      = "eth"
interface = "a"
[bus.eth1]
kind      = "eth"
interface = "b"
' +
		app)
	assert e.any(it.contains('one eth bus per image'))
}

fn test_someip_block_needs_an_eth_bus_and_traffic() {
	e := errs_of(
		'
[someip]
bus     = "eth0"
service = 1
version = 1
port    = 30490
peer    = "10.0.0.1:30490"
' +
		app)
	assert e.any(it.contains('no bus has kind = "eth"'))

	// an eth bus + [someip] but nothing riding the bus
	e2 := errs_of(eth_head + app)
	assert e2.any(it.contains('nothing rides bus "eth0"'))
}

fn test_someip_eth_frames_need_the_someip_block() {
	e := errs_of('
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"
' + eth_tx_frame + app)
	assert e.any(it.contains('no [someip] block'))
}

fn test_someip_signal_frame_id_must_be_an_event() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "CpuLoad"
fields = { load = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "BenchTelem"
bus     = "eth0"
id      = 0x0001
signals = ["CpuLoad"]
' +
		app)
	assert e.any(it.contains('not an event id'))
}

fn test_someip_event_ids_unique_and_one_frame_per_signal() {
	e := errs_of(eth_head + eth_tx_frame +
		'
[[frame]]
name    = "Twin"
bus     = "eth0"
id      = 0x8001
signals = ["CpuLoad"]
' + app)
	assert e.any(it.contains('reuses event id'))
	assert e.any(it.contains('rides two eth frames'))
}

fn test_someip_frame_direction_and_shape() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "OutSig"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[signal]]
name = "InSig"
fields = { v = "u8" }
from = "eth0"
to   = "app"

[[signal]]
name = "BadField"
fields = { name = "string" }
from = "app"
to   = "eth0"

[[frame]]
name    = "Mixed"
bus     = "eth0"
id      = 0x8001
signals = ["OutSig", "InSig", "BadField"]

[[frame]]
name    = "Empty"
bus     = "eth0"
id      = 0x8002
signals = []
' +
		app)
	assert e.any(it.contains('mixes tx and rx'))
	assert e.any(it.contains('not a fixed-width scalar'))
	assert e.any(it.contains('non-empty `signals` list'))
}

fn test_someip_payload_bound_is_the_shared_64() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "Big"
fields = { a = "u64", b = "u64", c = "u64", d = "u64", e = "u64", f = "u64", g = "u64", h = "u64", i = "u64" }
from = "app"
to   = "eth0"

[[frame]]
name    = "TooWide"
bus     = "eth0"
id      = 0x8001
signals = ["Big"]
' +
		app)
	assert e.any(it.contains('shared PDU bound is 64'))
}

fn test_someip_identity_ranges_and_peer() {
	e := errs_of(
		'
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"

[someip]
bus     = "eth0"
service = 0x10100
version = 300
port    = 0
peer    = "192.168.0.10"
' +
		eth_tx_frame + app)
	assert e.any(it.contains('service must fit 16 bits'))
	assert e.any(it.contains('version must fit 8 bits'))
	assert e.any(it.contains('port must be 1..65535'))
	assert e.any(it.contains('address:port'))
}

fn test_someip_e2e_trailer_counts_toward_the_bound() {
	// 8 u64 fields = exactly 64 bytes of layout; the 2-byte E2E trailer tips it.
	// Positions 0/1 are also wrong: the trailer appends at 64/65.
	e := errs_of(eth_head +
		'
[[signal]]
name = "Full"
fields = { a = "u64", b = "u64", c = "u64", d = "u64", e = "u64", f = "u64", g = "u64", h = "u64" }
from = "app"
to   = "eth0"

[[frame]]
name    = "Full64"
bus     = "eth0"
id      = 0x8001
signals = ["Full"]
e2e     = { data_id = 1, crc_pos = 0, counter_pos = 1 }
' +
		app)
	assert e.any(it.contains('E2E trailer included'))
	assert e.any(it.contains('counter_pos must equal the derived layout size (64)'))
}

fn test_someip_e2e_trailer_at_derived_offsets_ok() {
	// 6-byte layout: counter at 6, crc at 7 — valid, and within the bound
	e := errs_of(eth_head +
		'
[[signal]]
name = "Speed"
fields = { kph = "u32", flags = "u16" }
from = "app"
to   = "eth0"

[[frame]]
name    = "SpeedEvt"
bus     = "eth0"
id      = 0x8001
signals = ["Speed"]
e2e     = { data_id = 1, counter_pos = 6, crc_pos = 7 }

[[fb]]
name   = "SpeedWriter"
thread = "app_main"
  [[fb.handler]]
  name      = "on_100ms"
  period_ms = 100
  writes    = ["Speed"]
' +
		app)
	assert e == []
}

fn test_someip_secoc_on_eth_rejected() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "S"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "F"
bus     = "eth0"
id      = 0x8001
signals = ["S"]
secoc   = { key = "k1", data_id = 1, fresh_pos = 1, mac_pos = 2, mac_len = 4 }
' +
		app)
	assert e.any(it.contains('SecOC on eth is not defined'))
}

fn test_someip_signal_with_eth_on_both_sides_rejected() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "Loop"
fields = { v = "u8" }
from = "eth0"
to   = "eth0"

[[frame]]
name    = "F"
bus     = "eth0"
id      = 0x8001
signals = ["Loop"]
' +
		app)
	assert e.any(it.contains('names eth bus "eth0" on BOTH sides'))
}

fn test_someip_shell_on_eth_rejected_until_rpc() {
	e := errs_of(eth_head + '
[shell]
bus = "eth0"
in  = 0x8010
out = 0x8011
fc  = 0x8012
' +
		eth_tx_frame + app)
	assert e.any(it.contains('eth shell arrives with the RPC phase'))
}

fn test_someip_trace_inherits_telemetry_bus() {
	// [trace] omits bus -> inherits [telemetry].bus (the generators do); its
	// bad id must be caught even though telemetry itself is default-disabled
	e := errs_of(eth_head + '
[telemetry]
bus = "eth0"

[trace]
cmd = 0x0010
' + eth_tx_frame + app)
	assert e.any(it.contains('[trace] cmd id 0x10 on the eth bus is not an event id'))
}

fn test_someip_module_without_endpoints_is_not_traffic() {
	e := errs_of(eth_head + '
[trace]
bus = "eth0"
' + app)
	assert e.any(it.contains('[trace] is bound to eth bus "eth0" but binds no valid endpoint id'))
	assert e.any(it.contains('nothing rides bus "eth0"'))
}

fn test_someip_module_ids_join_the_event_space() {
	// trace enabled by default, bound to eth0: record collides with the frame,
	// cmd is a method-range id, rsp is a DBC-name string (no DBC on eth)
	e := errs_of(eth_head +
		'
[trace]
bus    = "eth0"
cmd    = 0x0010
rsp    = "TraceRsp"
record = 0x8001
' +
		eth_tx_frame + app)
	assert e.any(it.contains('[trace] record reuses event id'))
	assert e.any(it.contains('eth trace egress arrives with its own rung'))
	assert e.any(it.contains('[trace] cmd id 0x10 on the eth bus is not an event id'))
	assert e.any(it.contains('[trace] rsp on the eth bus must be a literal event id'))
}

fn test_someip_disabled_module_is_not_traffic() {
	// telemetry defaults DISABLED (loom2v): naming the eth bus is not traffic
	e := errs_of(eth_head + '
[telemetry]
bus = "eth0"
id  = 0x8002
' + app)
	assert e.any(it.contains('nothing rides bus "eth0"'))
}

fn test_someip_nm_on_eth_rejected() {
	e := errs_of(eth_head + '
[nm]
bus   = "eth0"
node  = 1
alive = 0x8003
' + eth_tx_frame + app)
	assert e.any(it.contains('NM over eth'))
}

fn test_someip_eth_bound_signal_must_ride_a_frame() {
	e := errs_of(eth_head + eth_tx_frame +
		'
[[signal]]
name = "Orphan"
fields = { v = "u8" }
from = "app"
to   = "eth0"
' + app)
	assert e.any(it.contains('signal "Orphan" is bound to eth bus "eth0" but rides no eth frame'))
}

fn test_someip_eth_keys_rejected_on_can_frames() {
	e := errs_of(
		'
[bus.can0]
interface = "vcan0"

[[frame]]
name    = "Legacy"
bus     = "can0"
id      = 0x123
signals = ["X"]
' +
		app)
	assert e.any(it.contains('declares eth-frame keys'))
}

fn test_someip_peer_address_must_be_ipv4() {
	e := errs_of(
		'
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"

[someip]
bus     = "eth0"
service = 1
version = 1
port    = 30490
peer    = "not-an-address:30490"
' +
		eth_tx_frame + app)
	assert e.any(it.contains('address:port'))

	e2 := errs_of(
		'
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"

[someip]
bus     = "eth0"
service = 1
version = 1
port    = 30490
peer    = "192.168.0.999:30490"
' +
		eth_tx_frame + app)
	assert e2.any(it.contains('address:port'))
}

fn test_someip_round3_gates() {
	// telemetry without explicit id; trace dump_fc; route touching eth;
	// e2e data_id over 16 bits — each must fail loud
	e := errs_of(eth_head +
		'
[telemetry]
enabled   = true
bus       = "eth0"
detail_id = 0x8005

[trace]
bus     = "eth0"
record  = 0x8002
dump_fc = 0x8003

[[signal]]
name = "Speed"
fields = { kph = "u32", flags = "u16" }
from = "app"
to   = "eth0"

[[frame]]
name    = "SpeedEvt"
bus     = "eth0"
id      = 0x8001
signals = ["Speed"]
e2e     = { data_id = 0x10000, counter_pos = 6, crc_pos = 7 }

[[route]]
from = { bus = "eth0", frame = "SpeedEvt" }
to   = { bus = "can0" }
' +
		app)
	assert e.any(it.contains('[telemetry] on eth bus "eth0" needs an explicit `id`'))
	assert e.any(it.contains('[trace] dump_fc is bound on the eth bus'))
	assert e.any(it.contains('E2E data_id must be an integer fitting 16 bits'))
	assert e.any(it.contains('a [[route]] touches eth bus "eth0"'))
}

fn test_someip_round4_gates() {
	// isotp on eth; a tx block on an rx frame; a string e2e data_id
	e := errs_of(eth_head +
		'
[[isotp]]
name  = "diag"
bus   = "eth0"
rx_id = 0x8100
tx_id = 0x8101

[[signal]]
name = "Cmd"
fields = { v = "u8" }
from = "eth0"
to   = "app"

[[frame]]
name    = "CmdEvt"
bus     = "eth0"
id      = 0x8001
signals = ["Cmd"]
tx      = { mode = "cyclic", cycle_ms = 100 }

[[signal]]
name = "Out"
fields = { v = "u16" }
from = "app"
to   = "eth0"

[[frame]]
name    = "OutEvt"
bus     = "eth0"
id      = 0x8002
signals = ["Out"]
rx      = { timeout_ms = 200 }
e2e     = { data_id = "nope", counter_pos = 2, crc_pos = 3 }
' +
		app)
	assert e.any(it.contains('[[isotp]] "diag" is bound to eth bus "eth0"'))
	assert e.any(it.contains('"CmdEvt" is rx (signals from the bus) but declares a tx block'))
	assert e.any(it.contains('"OutEvt" is tx (signals to the bus) but declares an rx block'))
	assert e.any(it.contains('E2E data_id must be an integer'))
}

fn test_someip_eth_frame_name_must_be_identifier() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "S"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "Bench,Telem"
bus     = "eth0"
id      = 0x8001
signals = ["S"]
' +
		app)
	assert e.any(it.contains('eth frame name "Bench,Telem" is not a valid identifier'))
}

fn test_someip_ioc_slot_bound_counts_padding() {
	// 5x u8 + 4x u64 alternating: wire = 37 bytes (fits), but the in-memory
	// struct is 72 after natural alignment — over the 64-byte IOC slot
	e := errs_of(eth_head +
		'
[[signal]]
name = "Padded"
fields = { a = "u8", b = "u64", c = "u8", d = "u64", e = "u8", f = "u64", g = "u8", h = "u64", i = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "PaddedEvt"
bus     = "eth0"
id      = 0x8001
signals = ["Padded"]
' +
		app)
	assert e.any(it.contains('in-memory struct is 72 bytes after alignment'))
}

fn test_someip_eth_ownership_spsc() {
	// two writers on a tx signal; a read of the same tx signal; and a writer
	// living outside the declared endpoint partition
	e := errs_of(eth_head +
		'
[[signal]]
name = "Dual"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[signal]]
name = "Stray"
fields = { v = "u8" }
from = "far"
to   = "eth0"

[[frame]]
name    = "Evt"
bus     = "eth0"
id      = 0x8001
signals = ["Dual", "Stray"]

[[partition]]
name = "far"
core = 0
  [[partition.thread]]
  name = "far_main"

[[fb]]
name   = "W1"
thread = "app_main"
  [[fb.handler]]
  name      = "on_10ms"
  period_ms = 10
  writes    = ["Dual", "Stray"]
  reads     = ["Dual"]

[[fb]]
name   = "W2"
thread = "far_main"
  [[fb.handler]]
  name      = "on_10ms"
  period_ms = 10
  writes    = ["Dual"]
' +
		app)
	assert e.any(it.contains('eth tx signal "Dual" is written from 2 execution contexts'))
	assert e.any(it.contains('eth tx signal "Dual" appears in a handler\'s reads'))
	assert e.any(it.contains('eth tx signal "Stray" is written from partition "app" but declares endpoint "far"'))
}

fn test_someip_round5_gates() {
	// snake-colliding frame names; a DID reading an eth signal
	e := errs_of(eth_head +
		'
[[signal]]
name = "A"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[signal]]
name = "B"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "FooBar"
bus     = "eth0"
id      = 0x8001
signals = ["A"]

[[frame]]
name    = "Foo_Bar"
bus     = "eth0"
id      = 0x8002
signals = ["B"]

[[did]]
id     = 0xF1A0
signal = "A"
' +
		app)
	assert e.any(it.contains('collides with "FooBar" after snake-case normalization'))
	assert e.any(it.contains('diagnostic DID reads eth signal "A"'))
}

fn test_someip_target_eth_telemetry_rejected() {
	e := errs_of(eth_head +
		'
[target]
kind = "threadx"

[telemetry]
enabled = true
bus     = "eth0"
id      = 0x8005
' +
		eth_tx_frame + app)
	assert e.any(it.contains('eth telemetry producer arrives'))
}

fn test_someip_rx_frames_accepted_and_e2e_rx_gated() {
	// P2: a plain rx frame is a valid config...
	ok := errs_of(eth_head +
		'
[[signal]]
name = "Cmd"
fields = { v = "u8" }
from = "eth0"
to   = "app"

[[frame]]
name    = "CmdEvt"
bus     = "eth0"
id      = 0x8001
signals = ["Cmd"]

[[fb]]
name = "Reader"
thread = "app_main"
  [[fb.handler]]
  name = "on_10ms"
  period_ms = 10
  reads = ["Cmd"]
' +
		app)
	assert ok == [], '${ok}'
	// ...but rx + e2e is gated until the rx-side check generates
	e := errs_of(eth_head +
		'
[[signal]]
name = "Cmd2"
fields = { v = "u8" }
from = "eth0"
to   = "app"

[[frame]]
name    = "CmdEvt2"
bus     = "eth0"
id      = 0x8001
signals = ["Cmd2"]
e2e     = { data_id = 1, counter_pos = 1, crc_pos = 2 }
' +
		app)
	assert e.any(it.contains('rx with e2e'))
}

fn test_someip_same_thread_double_write_is_single_context() {
	// two handlers of one FB (one Loom thread) publish serially — legal SPSC
	e := errs_of(eth_head +
		'
[[signal]]
name = "Twice"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "TwiceEvt"
bus     = "eth0"
id      = 0x8001
signals = ["Twice"]

[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "app_main"

[[fb]]
name   = "W"
thread = "app_main"
  [[fb.handler]]
  name      = "on_10ms"
  period_ms = 10
  writes    = ["Twice"]
  [[fb.handler]]
  name      = "on_100ms"
  period_ms = 100
  writes    = ["Twice"]
')
	assert e == []
}

fn test_someip_round7_gates() {
	// a bad tx mode; eth frames on a [target] image
	e := errs_of(eth_head +
		'
[target]
kind = "threadx"

[[signal]]
name = "S"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "Evt"
bus     = "eth0"
id      = 0x8001
signals = ["S"]
tx      = { mode = "cylic", cycle_ms = 100 }
' +
		app)
	assert e.any(it.contains('tx mode "cylic" is invalid'))
	assert e.any(it.contains('the target comm owner is CAN-only'))
}

fn test_someip_round8_timing_bounds() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "S"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "Evt"
bus     = "eth0"
id      = 0x8001
signals = ["S"]
tx      = { mode = "event", min_delay_ms = -1 }
' +
		app)
	assert e.any(it.contains('min_delay_ms must be 0..1000000'))
}

fn test_someip_round9_cycle_bounds_any_mode() {
	e := errs_of(eth_head +
		'
[[signal]]
name = "S"
fields = { v = "u8" }
from = "app"
to   = "eth0"

[[frame]]
name    = "Evt"
bus     = "eth0"
id      = 0x8001
signals = ["S"]
tx      = { mode = "event", cycle_ms = -1 }
' +
		app)
	assert e.any(it.contains('tx cycle_ms must be 1..1000000'))
}
