module cfgschema

// ecu: ecu.toml — one ECU. ecucheck walks it (check), the generators read it, and the leaf
// checks take their bounds from it. The diagnostic tables are in ecu_diag.v.
pub const ecu = ecu_schema()

fn ecu_schema() Schema {
	mut tables := [
		Table{
			ctx: 'top'
			label: '(top level)'
			desc: "The sections of an ecu.toml. Only what the node declares is generated; every section is optional to the walk, and the rules between sections (an fb's thread exists, a signal's endpoints resolve) are checked after it."
			keys: [
				sub('import', .tbl, 'import').doc("the DBC the node's CAN signals come from"),
				sub('telemetry', .tbl, 'telemetry').doc('the CPU-load transmitter'),
				sub('trace', .tbl, 'trace').doc('the trace ring and its dump protocol (docs/telemetry.md)'),
				sub('shell', .tbl, 'shell').doc('the command shell over CAN or SOME/IP'),
				sub('nm', .tbl, 'nm').doc("network management: the module's endpoint bindings and timings"),
				sub('nvm', .tbl, 'nvm').doc('the NvM journal: persisted signals and its wear check (docs/nvm.md)'),
				sub('target', .tbl, 'target').doc('what the node is built for: host (absent), bare metal or ThreadX'),
				sub('someip', .tbl, 'someip').doc('the SOME/IP service identity and static endpoints (docs/someip.md)'),
				sub('bus', .namedmap, 'bus').doc("the node's buses, one [bus.<name>] each; signals and frames name them"),
				sub('partition', .arr, 'partition').doc('memory-protection partitions, each pinned to a core with its threads'),
				sub('fb', .arr, 'fb').doc('Function Blocks: the application, scheduled on a thread'),
				sub('signal', .arr, 'signal').doc('typed signals between partitions and to/from buses'),
				sub('frame', .arr, 'frame').doc('per-frame COM settings: tx mode, rx deadline, E2E, SecOC (CAN), or a SOME/IP event (eth)'),
				sub('isotp', .tbl, 'isotp').doc('ISO 15765-2: the diagnostic server on CAN'),
				sub('uds', .tbl, 'uds').doc("ISO 14229: the node's one diagnostic server"),
				sub('doip', .tbl, 'doip').doc('the diagnostic server over DoIP too (ThreadX target)'),
				sub('boot', .tbl, 'boot').doc('the node runs behind the bootloader: 0x10 02 hands over to it (docs/bootloader.md)'),
				sub('display', .tbl, 'display').doc('a local screen: one more ThreadX thread (docs/display.md)'),
				sub('did', .arr, 'did').doc("the server's data identifiers"),
				sub('fault', .arr, 'fault').doc('diagnostic faults and their DTCs (docs/diagnostics.md §3.3)'),
				sub('param', .arr, 'param').doc('coded parameters (docs/diagnostics.md §3.4)'),
				sub('fault_memory', .tbl, 'fault_memory').doc("the fault memory's operation cycle and snapshot entries"),
				sub('route', .arr, 'route').doc('gateway routes: raw frames or decoded signals between buses'),
				sub('io', .tbl, 'io').doc('physical IO points (docs/io.md)'),
				sub('bulk', .arr, 'bulk').doc('bulk transport pools (docs/bulk-transport.md)'),
			]
		},
		tbl('import', '[import]', '', [
			k('dbc', .str).doc('the DBC comm matrix, relative to the node (read for provenance; generation takes the DBC on its command line)'),
		]),
		tbl('io', '[io]', 'Physical IO points (docs/io.md), each bound to the [[signal]] of the same name; at most 32.', [
			k('core', .int).d('0').doc("the io thread's home core; every io signal's partition must be on it"),
			sub('gpio', .arr, 'io_gpio').doc('digital pins'),
			sub('adc', .arr, 'io_adc').doc('analog inputs (at most 16, one scan sequence)'),
			sub('pwm', .arr, 'io_pwm').doc('PWM outputs'),
		]),
		tbl('io_gpio', '[[io.gpio]]', 'A digital pin: an input (the signal is from "io") or an output (to "io"), one bool field.', [
			req('name', .str).doc('binds the [[signal]] of the same name'),
			req('pin', .str).doc('the pad, backend-opaque (e.g. "PB0"); one point per pad'),
			req('period_ms', .int).doc('sample (input) or apply (output) period, ms >= 1, a multiple of the fastest io period'),
			k('init', .boolean).doc('outputs, REQUIRED there: the level held until the FB first publishes'),
			k('active_low', .boolean).d('false').doc('pad polarity: logical true drives the pad LOW'),
			k('default', .boolean).d('false').doc('inputs only: the port value before the first real sample'),
		]),
		tbl('io_adc', '[[io.adc]]', 'An analog input bound to a u16/u32 [[signal]] from "io".', [
			req('name', .str).doc('binds a u16/u32 [[signal]] (input only)'),
			req('pin', .str).doc('the ADC pad / channel'),
			req('period_ms', .int).doc('the PUBLISH cadence (ms >= 1); the conversion free-runs'),
			k('default', .int).d('0').doc('the count held until the first real sample (within the field type)'),
		]),
		tbl('io_pwm', '[[io.pwm]]', 'A PWM output bound to a u16/u32 [[signal]] to "io" carrying duty in permille.', [
			req('name', .str).doc('binds a u16/u32 [[signal]] carrying permille (output only)'),
			req('pin', .str).doc('the PWM pad'),
			req('period_ms', .int).doc('the APPLY cadence (ms >= 1)'),
			req('freq_hz', .int).range(1, 10_000_000).own_check().doc('the carrier frequency'),
			k('init', .int).range(0, 1000).own_check().doc('the duty (permille) before the first publish; required on an output'),
		]),
		tbl('telemetry', '[telemetry]', 'The CPU-load transmitter (CpuLoad, LoadDetail); [trace] and [shell] take its bus when they name none.', [
			k('enabled', .boolean).d('false').doc('transmit load telemetry (a ThreadX target needs it on, with a bus)'),
			k('bus', .str).doc('the CAN bus the load frames ride'),
			k('id', .int).doc("the CpuLoad frame's CAN id"),
			k('detail_id', .int).doc("the LoadDetail frame's CAN id; absent = not sent"),
			k('period_ms', .int).d('1000').doc('the transmit period (ms)'),
		]),
		tbl('shell', '[shell]', 'The command shell: a command line in, its response out, over CAN or as a SOME/IP method.', [
			k('enabled', .boolean).d('true').doc('generate the shell (present = on)'),
			k('bus', .str).doc('the bus its frames ride; absent = [telemetry].bus'),
			k('in', .id).d('0x7F0').doc('the frame a command line arrives on (1..8 bytes)'),
			k('out', .id).d('0x7F1').doc('the frame the response leaves on (one ISO-TP block)'),
			k('fc', .id).d('0x7F2').doc('the ISO-TP flow control for the response'),
			k('commands', .str_arr).d('[]').doc('example-provided target commands (shell_<name> in target_ext.c), each 1..8 of [a-z0-9_]'),
			k('method', .id).range(0x0001, 0x7FFF).hex().own_check().doc('eth: the SOME/IP method id the command line rides (required there)'),
			k('allow_mutate', .boolean).d('false').doc('the REQ-NET-018 access gate: false exposes only read-class commands over eth'),
		]),
		tbl('nvm', '[nvm]', 'The NvM journal: persisted signals, and the wear check that proves it outlives the vehicle (docs/nvm.md).', [
			k('enabled', .boolean).doc('declare the journal; default true when [nvm] has a key besides `assume`'),
			k('min_write_ms', .int).d('1000').range(1, 86_400_000).doc('the system-wide write floor pacing persist = "now" writes (ms)'),
			k('sector_records', .int).d('4096').range(8, 1_000_000).doc("a journal sector in records (the wear check's geometry)"),
			k('endurance', .int).d('10000').range(1, 10_000_000).doc('flash erase cycles per sector'),
			k('min_years', .int).d('10').range(1, 100).doc('the lifetime the journal must reach at the assumed rates'),
			sub('assume', .tbl, 'nvm_assume').doc("the vehicle's rates the wear check takes"),
		]),
		tbl('nvm_assume', '[nvm.assume]', 'Vehicle usage rates the wear check assumes, per day.', [
			k('cycles_per_day', .int).d('144').range(1, 1_000_000).doc('operation cycles: NM wake -> sleep, or power-ups'),
			k('resets_per_day', .int).d('24').range(0, 1_000_000).doc('ECUResets (0x11)'),
			k('clears_per_day', .int).d('24').range(0, 1_000_000).doc('ClearDiagnosticInformation (0x14)'),
			k('setting_changes_per_day', .int).d('24').range(0, 1_000_000).doc('ControlDTCSetting (0x85) changes'),
			k('codings_per_day', .int).d('24').range(0, 1_000_000).doc('accepted 0x2E codings of a [[param]]'),
		]),
		Table{
			ctx: 'nm'
			label: '[nm]'
			desc: "Network management (comm/nm_can). The scalar keys are the module's endpoint bindings and timings."
			table_keys: 'nm_net'
			keys: [
				k('enabled', .boolean).doc('generate the NM module; default true when [nm] has scalar keys'),
				k('bus', .str).doc('the CAN bus NM runs on; absent = [telemetry].bus'),
				k('node', .int).range(0, 255).doc("this ECU's NM source node id (required when NM is generated)"),
				k('pn', .int).d('0').doc('the partial networks this node requests (bitmask)'),
				k('request', .boolean).d('true').doc('request the bus from boot'),
				k('msg_cycle_ms', .int).d('100').doc('the NM message period while awake (ms)'),
				k('timeout_ms', .int).d('300').doc('the NM timeout (ms)'),
				k('repeat_ms', .int).d('200').doc('the repeat-message phase after a wake (ms)'),
				k('wait_sleep_ms', .int).d('150').doc('the prepare-bus-sleep wait (ms)'),
				k('alive', .id).doc("this node's NM frame (DBC name or id); default peers lo + node"),
				k('peers', .id_range).d('[0x500, 0x53F]').doc("[lo, hi] — the cluster's NM frame ids"),
			]
		},
		tbl('nm_net', '[nm.*]', "The LEGACY per-network NM block (cfg2v's gen.nm_<bus>_* constants), beside the module bindings of [nm].", [
			k('node_id', .int).d('0').doc('the source node id'),
			k('tx_id', .int).d('0').doc("this node's NM tx id"),
			k('rx_lo', .int).doc("the NM rx id range's low bound (required by cfg2v)"),
			k('rx_hi', .int).doc("the NM rx id range's high bound (required by cfg2v)"),
			k('pn_local', .int).d('0').doc('the partial networks requested statically (48-bit mask)'),
			k('msg_cycle_ms', .int).d('0').doc('the NM message period (ms)'),
			k('timeout_ms', .int).d('0').doc('the NM timeout (ms)'),
			k('repeat_ms', .int).d('0').doc('the repeat-message phase (ms)'),
			k('wait_sleep_ms', .int).d('0').doc('the prepare-bus-sleep wait (ms)'),
		]),
		tbl('trace', '[trace]', 'The trace ring and its dump protocol (docs/telemetry.md). A present block is on unless enabled = false.', [
			k('enabled', .boolean).d('true').doc('generate the trace (present = on)'),
			k('bus', .str).doc('the CAN bus for its command / response / dump frames; absent = [telemetry].bus'),
			k('level', .str).d('"thread+fb"').one_of(['fb', 'thread', 'thread+isr', 'thread+fb',
				'all']).own_check().doc('which records are captured: FB, thread and ISR switches'),
			k('buffer_records', .int).d('64').range(1, 4096).own_check().doc('the ring depth in 8-byte records (the dump is multi-block)'),
			k('mode', .str).d('"ring"').one_of(['ring', 'oneshot']).own_check().doc('ring = a flight recorder frozen by a trigger or stop; oneshot = fill once'),
			k('pre_pct', .int).d('50').range(0, 100).own_check().doc('the percentage of the ring kept from before the trigger'),
			k('push_ms', .int).d('1000').at_least(0).own_check().doc('the HandlerStat heartbeat period (ms; 0 = off)'),
			k('cmd', .id).d('0x7E2').doc('the TraceCmd frame: arm / stop / reset / dump / status'),
			k('rsp', .id).d('0x7E3').doc('the command response frame'),
			k('record', .id).d('0x7E5').doc('the dump stream frame (raw records, or ISO-TP blocks)'),
			k('dump_fc', .id).d('0x7E6').doc("the dump's ISO-TP flow control; binding it selects the block dump"),
			sub('trigger', .tbl, 'trigger').doc('what freezes the ring; absent = no trigger'),
		]),
		tbl('trigger', '[trace.trigger]', 'What freezes the ring. Only source = "overrun" is generated today; the other keys are the design\'s (docs/telemetry.md).', [
			k('source', .str).one_of(['overrun']).own_check().doc('the trigger kind (required when the table is present)'),
			k('signal', .str).doc('design only: the signal to watch'),
			k('address', .str).doc('design only: the partition-local address to poll'),
			k('when', .str).doc('design only: the condition on the watched value'),
			k('pre', .int).doc('design only (the implemented split is [trace] pre_pct)'),
			k('budget_us', .int).at_least(1).own_check().doc('source = "overrun": freeze when a handler runs longer than this (µs)'),
		]),
		tbl('target', '[target]', 'What the node is built for; absent = the host (POSIX) build.', [
			k('kind', .str).one_of(['baremetal', 'threadx']).doc('"baremetal" (superloop) or "threadx" (RTOS); absent = host'),
			k('tick_ms', .int).d('1').doc('the scheduler tick (ms)'),
		]),
		tbl('bus', '[bus.*]', "One of the node's buses: a CAN channel or the eth interface.", [
			req('interface', .str).doc('the platform interface (e.g. "vcan0"), or on eth the node\'s static IPv4 address'),
			k('fd', .boolean).d('false').doc('open the channel as CAN-FD'),
			k('core', .int).d('0').doc('the core the bus bridge runs on'),
			k('kind', .str).d('"can"').one_of(['can', 'eth']).own_check().doc('"can", or "eth" (SOME/IP, docs/someip.md; at most one)'),
			k('dbc', .str).doc('a per-bus DBC (a multi-bus GATEWAY speaks more than one contract)'),
		]),
		tbl('someip', '[someip]', 'The SOME/IP service identity and static endpoints (docs/someip.md). Deliberately no `instance`: without SD nothing on the wire carries it.', [
			req('bus', .str).doc('the eth bus it binds to'),
			req('service', .int).range(0, 0xFFFF).hex().own_check().doc('the SOME/IP service id'),
			req('version', .int).range(0, 0xFF).own_check().doc('the interface version byte, explicitly managed'),
			req('port', .int).range(1, 0xFFFF).own_check().doc('the local UDP port'),
			req('peer', .str).doc('address:port — the tx destination AND the rx source filter'),
		]),
		tbl('partition', '[[partition]]', 'A memory-protection partition, pinned to a core, with its threads.', [
			k('name', .str).doc('identifier, unique (required; "io" is reserved)'),
			k('core', .int).doc('the core index it is pinned to (required)'),
			k('trusted', .boolean).d('false').doc('privileged: the MPU domain with peripheral / IO access'),
			k('external', .boolean).d('false').doc("declared but hand-written: a satellite core's image built elsewhere"),
			k('image', .str).doc("emit this partition's image into this directory (docs/multi-image.md; ThreadX)"),
			sub('thread', .arr, 'thread').doc('its threads, 1..4 (required)'),
		]),
		tbl('thread', '[[partition.thread]]', 'A thread; an fb names it to run there.', [
			k('name', .str).doc('identifier, unique across the node (required)'),
			k('priority', .int).d('10').doc('scheduling priority, lower = higher (ThreadX: 0..31)'),
		]),
		tbl('fb', '[[fb]]', 'A Function Block: the application unit, scheduled on one thread.', [
			k('name', .str).doc('PascalCase, unique (required)'),
			k('thread', .str).doc('the [[partition.thread]] it runs on (required)'),
			sub('handler', .arr, 'handler').doc('its handlers, at least one'),
		]),
		tbl('handler', '[[fb.handler]]', 'A handler: an FB entry point the Loom dispatches.', [
			k('name', .str).doc('identifier (required)'),
			k('period_ms', .int).doc('the period it runs at (ms; the trigger, required)'),
			k('irq', .str).doc('reserved: an interrupt trigger, refused until it is generated'),
			k('reads', .str_arr).d('[]').doc('the signals (and params) it reads'),
			k('writes', .str_arr).d('[]').doc('the signals it writes'),
		]),
		tbl('signal', '[[signal]]', 'A typed signal from one endpoint to another: a partition, a thread, a bus, or "io".', [
			req('name', .str).doc('PascalCase; a signal a bus carries takes its DBC name'),
			sub('fields', .str_map, '').required().doc("field name -> type, the signal's struct"),
			req('from', .str).doc('the producer: a partition, thread, bus or "io"'),
			req('to', .str).doc('the consumer: a partition, thread, bus or "io"'),
			k('transport', .str).d('"double"').one_of(['double', 'triple', 'seqlock', 'dma', 'hw_sem',
				'mailbox']).doc('the IOC buffer between partitions (derived for io signals); the hardware ones are target backends, double on host'),
			k('persist', .str).one_of(['now', 'shutdown']).doc('keep it in NvM: write-through, or flush at sleep — intent, not tuning (docs/nvm.md)'),
			k('nvm_id', .int).d('0').range(0, 0xFFFE).doc('pins the NvM record id (0 = derived; only to resolve a reported collision)'),
		]),
		tbl('frame', '[[frame]]', 'Per-frame COM settings. CAN: the DBC message `name` and its tx / rx / E2E / SecOC. eth: a SOME/IP event, its id and signals.', [
			req('name', .str).doc('CAN: the DBC message; eth: the event (PascalCase)'),
			req('bus', .str).doc('the [bus.*] it travels on'),
			k('id', .int).range(0x8000, 0xFFFF).hex().own_check().doc('eth: the SOME/IP event id (required there; CAN ids come from the DBC)'),
			k('signals', .str_arr).doc('eth: its member signals; the payload layout is derived from them'),
			k('peer', .str).doc("eth: this event's own address:port, when not [someip].peer"),
			sub('tx', .tbl, 'tx').doc('how it is sent'),
			sub('rx', .tbl, 'rx').doc('the receive deadline'),
			sub('e2e', .tbl, 'e2e').doc("AUTOSAR E2E Profile 1 (the DBC's E2E attributes otherwise)"),
			sub('secoc', .tbl, 'secoc').doc('SecOC: AES-CMAC (CAN only)'),
		]),
		tbl('tx', 'inline tx', 'How a frame is sent (comm/com).', [
			k('mode', .str).d('"cyclic"').one_of(['cyclic', 'event', 'mixed', 'triggered']).doc('periodic, on a change, both, or on an explicit trigger (eth: not triggered)'),
			k('cycle_ms', .int).doc("the period of a cyclic or mixed frame (ms). Absent: CAN takes the DBC's GenMsgCycleTime, else 100, in multiples of 10; eth takes 100, within 1..1000000"),
			k('min_delay_ms', .int).d('0').doc('the least gap between two event sends (ms; eth: 0..1000000)'),
		]),
		tbl('rx', 'inline rx', '', [
			k('timeout_ms', .int).d('0').range(0, 2147483).doc('the reception deadline (ms; 0 = none); past it the signal status is timeout'),
		]),
		tbl('e2e', 'inline e2e', "AUTOSAR E2E Profile 1. Each key defaults to the DBC's E2E attribute; a differing value needs deviates_from_dbc.", [
			k('data_id', .int).range(0, 0xFFFF).hex().own_check().doc('the Data ID mixed into the CRC'),
			k('crc_pos', .int).doc("the CRC's byte"),
			k('counter_pos', .int).doc('the byte whose low nibble holds the counter'),
			k('timeout_ms', .int).range(0, 2147483).doc('rx: the E2E-owned sender-loss timeout (ms; REQ-E2E-002)'),
			k('deviates_from_dbc', .boolean).d('false').doc("a field above that differs from the DBC's E2E attributes is deliberate"),
		]),
		tbl('secoc', 'inline secoc', 'SecOC: a truncated AES-128 CMAC and a freshness value in the frame.', [
			k('key', .str).doc('the AES-128 key, 16 space-separated hex bytes (required)'),
			k('data_id', .int).d('0').range(0, 0xFFFF).hex().doc('the Data ID bound into the MAC'),
			k('fresh_pos', .int).d('0').doc("the freshness value's byte"),
			k('mac_pos', .int).d('0').doc("the MAC's first byte"),
			k('mac_len', .int).d('4').range(1, 16).doc("the truncated MAC's length (bytes)"),
		]),
		tbl('route', '[[route]]', 'A gateway route: forward a raw frame, or decode a signal and re-encode it (CAN only).', [
			k('signal', .str).doc('a SIGNAL route: decode it on `from`, re-encode it into `to`; absent = a raw frame route'),
			sub('from', .tbl, 'route_from').required().doc('the source'),
			sub('to', .tbl, 'route_to').required().doc('the destination'),
		]),
		tbl('route_from', '[[route]] from', '', [
			req('bus', .str).doc('the source bus'),
			req('frame', .str).doc('the DBC frame to forward / decode'),
		]),
		tbl('route_to', '[[route]] to', '', [
			req('bus', .str).doc('the destination bus'),
			k('frame', .str).doc('SIGNAL route: the destination DBC frame to re-encode into (required there)'),
			k('id', .int).d('0').range(0, 0x1FFFFFFF).hex().doc('FRAME route: the id on the destination bus (0 = keep the source id)'),
		]),
		tbl('bulk', '[[bulk]]', 'A bulk transport pool (docs/bulk-transport.md): a producer/consumer SPSC ring of buffers. Same partition = a per-image arena; different cores = the H755 shared window.', [
			req('name', .str).doc('identifier, unique'),
			req('producer', .str).doc('a partition or thread name'),
			req('consumer', .str).doc('a partition or thread name'),
			req('bufsz', .int).range(1, 1_048_576).own_check().doc('bytes per buffer, a multiple of 32'),
			req('nbuf', .int).range(1, 1024).own_check().doc('the ring depth'),
		]),
		tbl('display', '[display]', 'A local screen: one more ThreadX thread (boards/<board>/display.c, docs/display.md).', [
			req('ui', .str).doc("the node's screen (ui_create, ui_update): a C file relative to the node"),
		]),
		tbl('boot', '[boot]', 'The node runs behind the bootloader (docs/bootloader.md).', [
			req('image_key', .str).doc('the image-signing PUBLIC key, 64 hex (Ed25519)'),
			req('session_key', .str).doc('the 0x29 session PUBLIC key, 64 hex; not the image key'),
		]),
	]
	tables << ecu_diag_tables()
	return Schema{
		file: 'ecu.toml'
		root: 'top'
		title: 'blobly_emb ECU configuration: partitions, threads, Function Blocks, signals, buses and services of one node'
		desc: 'One ECU (docs/architecture.md). `ecucheck` validates it before any generator runs; `loom2v`, `cfg2v` and `sigmap` read it.'
		tables: tables
	}
}
