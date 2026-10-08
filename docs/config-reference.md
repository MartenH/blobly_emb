# Configuration reference

<!-- GENERATED from tools/cfgschema by tools/cfgdoc — do not edit. `make config-docs` regenerates
this file and schema/*.schema.json; `make check` fails when either is stale. -->

Every table and key of the two configuration files, generated from the ONE schema the tools
validate against (`tools/cfgschema`): `ecucheck` refuses an unknown key, a wrong type or a missing
required key from it, and the range and enumeration checks read their bounds from it. What a key
MEANS beyond one line — and the rules that relate keys to each other, which no single row can
state — is in the docs each section links to: [architecture.md](architecture.md),
[multi-node.md](multi-node.md), [diagnostics.md](diagnostics.md), [communication.md](communication.md).

- **ecu.toml** — one ECU (a node): its partitions, threads, Function Blocks, signals, buses and
  services. A node of a dissolved system authors only its internals; `sysgen` writes the complete
  file as `gen-<node>.toml`, which is an ecu.toml and validates against the same schema.
- **system.toml** — a system of ECUs: the buses, the cross-node signals and frames, the routes and
  each node's identities (docs/multi-node.md).

Editors: `.taplo.toml` maps both files (and `gen-*.toml`) to the JSON Schemas in `schema/`, so
Even Better TOML / Taplo complete keys, show these descriptions on hover and validate as you type.

A default of "—" means the key has no single default: it is required, or what its absence means is
in its description. Integer ranges are inclusive.

## ecu.toml

One ECU (docs/architecture.md). `ecucheck` validates it before any generator runs; `loom2v`, `cfg2v` and `sigmap` read it.

<a id="ecu-top"></a>

### `(top level)`

The sections of an ecu.toml. Only what the node declares is generated; every section is optional to the walk, and the rules between sections (an fb's thread exists, a signal's endpoints resolve) are checked after it.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `import` | table → [`[import]`](#ecu-import) |  | — |  | the DBC the node's CAN signals come from |
| `telemetry` | table → [`[telemetry]`](#ecu-telemetry) |  | — |  | the CPU-load transmitter |
| `trace` | table → [`[trace]`](#ecu-trace) |  | — |  | the trace ring and its dump protocol (docs/telemetry.md) |
| `shell` | table → [`[shell]`](#ecu-shell) |  | — |  | the command shell over CAN or SOME/IP |
| `nm` | table → [`[nm]`](#ecu-nm) |  | — |  | network management: the module's endpoint bindings and timings |
| `nvm` | table → [`[nvm]`](#ecu-nvm) |  | — |  | the NvM journal: persisted signals and its wear check (docs/nvm.md) |
| `target` | table → [`[target]`](#ecu-target) |  | — |  | what the node is built for: host (absent), bare metal or ThreadX |
| `someip` | table → [`[someip]`](#ecu-someip) |  | — |  | the SOME/IP service identity and static endpoints (docs/someip.md) |
| `bus` | tables by name → [`[bus.*]`](#ecu-bus) |  | — |  | the node's buses, one [bus.<name>] each; signals and frames name them |
| `partition` | array of tables → [`[[partition]]`](#ecu-partition) |  | — |  | memory-protection partitions, each pinned to a core with its threads |
| `fb` | array of tables → [`[[fb]]`](#ecu-fb) |  | — |  | Function Blocks: the application, scheduled on a thread |
| `signal` | array of tables → [`[[signal]]`](#ecu-signal) |  | — |  | typed signals between partitions and to/from buses |
| `frame` | array of tables → [`[[frame]]`](#ecu-frame) |  | — |  | per-frame COM settings: tx mode, rx deadline, E2E, SecOC (CAN), or a SOME/IP event (eth) |
| `isotp` | table → [`[isotp]`](#ecu-isotp) |  | — |  | ISO 15765-2: the diagnostic server on CAN |
| `uds` | table → [`[uds]`](#ecu-uds) |  | — |  | ISO 14229: the node's one diagnostic server |
| `doip` | table → [`[doip]`](#ecu-doip) |  | — |  | the diagnostic server over DoIP too (ThreadX target) |
| `boot` | table → [`[boot]`](#ecu-boot) |  | — |  | the node runs behind the bootloader: 0x10 02 hands over to it (docs/bootloader.md) |
| `display` | table → [`[display]`](#ecu-display) |  | — |  | a local screen: one more ThreadX thread (docs/display.md) |
| `did` | array of tables → [`[[did]]`](#ecu-did) |  | — |  | the server's data identifiers |
| `fault` | array of tables → [`[[fault]]`](#ecu-fault) |  | — |  | diagnostic faults and their DTCs (docs/diagnostics.md §3.3) |
| `param` | array of tables → [`[[param]]`](#ecu-param) |  | — |  | coded parameters (docs/diagnostics.md §3.4) |
| `fault_memory` | table → [`[fault_memory]`](#ecu-fault-memory) |  | — |  | the fault memory's operation cycle and snapshot entries |
| `route` | array of tables → [`[[route]]`](#ecu-route) |  | — |  | gateway routes: raw frames or decoded signals between buses |
| `io` | table → [`[io]`](#ecu-io) |  | — |  | physical IO points (docs/io.md) |
| `bulk` | array of tables → [`[[bulk]]`](#ecu-bulk) |  | — |  | bulk transport pools (docs/bulk-transport.md) |

<a id="ecu-import"></a>

### `[import]`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `dbc` | string |  | — |  | the DBC comm matrix, relative to the node (read for provenance; generation takes the DBC on its command line) |

<a id="ecu-telemetry"></a>

### `[telemetry]`

The CPU-load transmitter (CpuLoad, LoadDetail); [trace] and [shell] take its bus when they name none.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `enabled` | boolean |  | `false` |  | transmit load telemetry (a ThreadX target needs it on, with a bus) |
| `bus` | string |  | — |  | the CAN bus the load frames ride |
| `id` | integer |  | — |  | the CpuLoad frame's CAN id |
| `detail_id` | integer |  | — |  | the LoadDetail frame's CAN id; absent = not sent |
| `period_ms` | integer |  | `1000` |  | the transmit period (ms) |

<a id="ecu-trace"></a>

### `[trace]`

The trace ring and its dump protocol (docs/telemetry.md). A present block is on unless enabled = false.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `enabled` | boolean |  | `true` |  | generate the trace (present = on) |
| `bus` | string |  | — |  | the CAN bus for its command / response / dump frames; absent = [telemetry].bus |
| `level` | string |  | `"thread+fb"` | `"fb"`, `"thread"`, `"thread+isr"`, `"thread+fb"`, `"all"` | which records are captured: FB, thread and ISR switches |
| `buffer_records` | integer |  | `64` | 1..4096 | the ring depth in 8-byte records (the dump is multi-block) |
| `mode` | string |  | `"ring"` | `"ring"`, `"oneshot"` | ring = a flight recorder frozen by a trigger or stop; oneshot = fill once |
| `pre_pct` | integer |  | `50` | 0..100 | the percentage of the ring kept from before the trigger |
| `push_ms` | integer |  | `1000` | >= 0 | the HandlerStat heartbeat period (ms; 0 = off) |
| `cmd` | CAN id or DBC message name |  | `0x7E2` |  | the TraceCmd frame: arm / stop / reset / dump / status |
| `rsp` | CAN id or DBC message name |  | `0x7E3` |  | the command response frame |
| `record` | CAN id or DBC message name |  | `0x7E5` |  | the dump stream frame (raw records, or ISO-TP blocks) |
| `dump_fc` | CAN id or DBC message name |  | `0x7E6` |  | the dump's ISO-TP flow control; binding it selects the block dump |
| `trigger` | table → [`[trace.trigger]`](#ecu-trigger) |  | — |  | what freezes the ring; absent = no trigger |

<a id="ecu-trigger"></a>

### `[trace.trigger]`

What freezes the ring. Only source = "overrun" is generated today; the other keys are the design's (docs/telemetry.md).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `source` | string |  | — | `"overrun"` | the trigger kind (required when the table is present) |
| `signal` | string |  | — |  | design only: the signal to watch |
| `address` | string |  | — |  | design only: the partition-local address to poll |
| `when` | string |  | — |  | design only: the condition on the watched value |
| `pre` | integer |  | — |  | design only (the implemented split is [trace] pre_pct) |
| `budget_us` | integer |  | — | >= 1 | source = "overrun": freeze when a handler runs longer than this (µs) |

<a id="ecu-shell"></a>

### `[shell]`

The command shell: a command line in, its response out, over CAN or as a SOME/IP method.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `enabled` | boolean |  | `true` |  | generate the shell (present = on) |
| `bus` | string |  | — |  | the bus its frames ride; absent = [telemetry].bus |
| `in` | CAN id or DBC message name |  | `0x7F0` |  | the frame a command line arrives on (1..8 bytes) |
| `out` | CAN id or DBC message name |  | `0x7F1` |  | the frame the response leaves on (one ISO-TP block) |
| `fc` | CAN id or DBC message name |  | `0x7F2` |  | the ISO-TP flow control for the response |
| `commands` | array of strings |  | `[]` |  | example-provided target commands (shell_<name> in target_ext.c), each 1..8 of [a-z0-9_] |
| `method` | CAN id or DBC message name |  | — | 0x1..0x7FFF | eth: the SOME/IP method id the command line rides (required there) |
| `allow_mutate` | boolean |  | `false` |  | the REQ-NET-018 access gate: false exposes only read-class commands over eth |

<a id="ecu-nm"></a>

### `[nm]`

Network management (comm/nm_can). The scalar keys are the module's endpoint bindings and timings.

Any other key holding a table is read as [`[nm.*]`](#ecu-nm-net).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `enabled` | boolean |  | — |  | generate the NM module; default true when [nm] has scalar keys |
| `bus` | string |  | — |  | the CAN bus NM runs on; absent = [telemetry].bus |
| `node` | integer |  | — | 0..255 | this ECU's NM source node id (required when NM is generated) |
| `pn` | integer |  | `0` |  | the partial networks this node requests (bitmask) |
| `request` | boolean |  | `true` |  | request the bus from boot |
| `msg_cycle_ms` | integer |  | `100` |  | the NM message period while awake (ms) |
| `timeout_ms` | integer |  | `300` |  | the NM timeout (ms) |
| `repeat_ms` | integer |  | `200` |  | the repeat-message phase after a wake (ms) |
| `wait_sleep_ms` | integer |  | `150` |  | the prepare-bus-sleep wait (ms) |
| `alive` | CAN id or DBC message name |  | — |  | this node's NM frame (DBC name or id); default peers lo + node |
| `peers` | [lo, hi] of integers |  | `[0x500, 0x53F]` |  | [lo, hi] — the cluster's NM frame ids |

<a id="ecu-nm-net"></a>

### `[nm.*]`

The LEGACY per-network NM block (cfg2v's gen.nm_<bus>_* constants), beside the module bindings of [nm].

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `node_id` | integer |  | `0` |  | the source node id |
| `tx_id` | integer |  | `0` |  | this node's NM tx id |
| `rx_lo` | integer |  | — |  | the NM rx id range's low bound (required by cfg2v) |
| `rx_hi` | integer |  | — |  | the NM rx id range's high bound (required by cfg2v) |
| `pn_local` | integer |  | `0` |  | the partial networks requested statically (48-bit mask) |
| `msg_cycle_ms` | integer |  | `0` |  | the NM message period (ms) |
| `timeout_ms` | integer |  | `0` |  | the NM timeout (ms) |
| `repeat_ms` | integer |  | `0` |  | the repeat-message phase (ms) |
| `wait_sleep_ms` | integer |  | `0` |  | the prepare-bus-sleep wait (ms) |

<a id="ecu-nvm"></a>

### `[nvm]`

The NvM journal: persisted signals, and the wear check that proves it outlives the vehicle (docs/nvm.md).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `enabled` | boolean |  | — |  | declare the journal; default true when [nvm] has a key besides `assume` |
| `min_write_ms` | integer |  | `1000` | 1..86400000 | the system-wide write floor pacing persist = "now" writes (ms) |
| `sector_records` | integer |  | `4096` | 8..1000000 | a journal sector in records (the wear check's geometry) |
| `endurance` | integer |  | `10000` | 1..10000000 | flash erase cycles per sector |
| `min_years` | integer |  | `10` | 1..100 | the lifetime the journal must reach at the assumed rates |
| `assume` | table → [`[nvm.assume]`](#ecu-nvm-assume) |  | — |  | the vehicle's rates the wear check takes |

<a id="ecu-nvm-assume"></a>

### `[nvm.assume]`

Vehicle usage rates the wear check assumes, per day.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `cycles_per_day` | integer |  | `144` | 1..1000000 | operation cycles: NM wake -> sleep, or power-ups |
| `resets_per_day` | integer |  | `24` | 0..1000000 | ECUResets (0x11) |
| `clears_per_day` | integer |  | `24` | 0..1000000 | ClearDiagnosticInformation (0x14) |
| `setting_changes_per_day` | integer |  | `24` | 0..1000000 | ControlDTCSetting (0x85) changes |
| `codings_per_day` | integer |  | `24` | 0..1000000 | accepted 0x2E codings of a [[param]] |

<a id="ecu-target"></a>

### `[target]`

What the node is built for; absent = the host (POSIX) build.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `kind` | string |  | — | `"baremetal"`, `"threadx"` | "baremetal" (superloop) or "threadx" (RTOS); absent = host |
| `tick_ms` | integer |  | `1` |  | the scheduler tick (ms) |

<a id="ecu-someip"></a>

### `[someip]`

The SOME/IP service identity and static endpoints (docs/someip.md). Deliberately no `instance`: without SD nothing on the wire carries it.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `bus` | string | yes | — |  | the eth bus it binds to |
| `service` | integer | yes | — | 0x0..0xFFFF | the SOME/IP service id |
| `version` | integer | yes | — | 0..255 | the interface version byte, explicitly managed |
| `port` | integer | yes | — | 1..65535 | the local UDP port |
| `peer` | string | yes | — |  | address:port — the tx destination AND the rx source filter |

<a id="ecu-bus"></a>

### `[bus.*]`

One of the node's buses: a CAN channel or the eth interface.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `interface` | string | yes | — |  | the platform interface (e.g. "vcan0"), or on eth the node's static IPv4 address |
| `fd` | boolean |  | `false` |  | open the channel as CAN-FD |
| `core` | integer |  | `0` |  | the core the bus bridge runs on |
| `kind` | string |  | `"can"` | `"can"`, `"eth"` | "can", or "eth" (SOME/IP, docs/someip.md; at most one) |
| `dbc` | string |  | — |  | a per-bus DBC (a multi-bus GATEWAY speaks more than one contract) |
| `netmask` | string |  | — | dotted IPv4 | eth only (a CAN bus has none): the subnet mask the node is brought up on; contiguous, /1../30, equal to [doip]'s where the node has one. Absent = 255.255.255.0 |
| `gateway` | string |  | — | dotted IPv4 | eth only (a CAN bus has none): the default gateway; inside interface/netmask and not its network or broadcast address. Absent = the subnet's first host, (address & netmask) \| 1 |

<a id="ecu-partition"></a>

### `[[partition]]`

A memory-protection partition, pinned to a core, with its threads.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | identifier, unique (required; "io" is reserved) |
| `core` | integer | yes | — |  | the core index it is pinned to (required) |
| `trusted` | boolean |  | `false` |  | privileged: the MPU domain with peripheral / IO access |
| `external` | boolean |  | `false` |  | declared but hand-written: a satellite core's image built elsewhere |
| `image` | string |  | — |  | emit this partition's image into this directory (docs/multi-image.md; ThreadX) |
| `thread` | array of tables → [`[[partition.thread]]`](#ecu-thread) | yes | — |  | its threads, 1..4 (required) |

<a id="ecu-thread"></a>

### `[[partition.thread]]`

A thread; an fb names it to run there.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | identifier, unique across the node (required) |
| `priority` | integer |  | `10` |  | scheduling priority, lower = higher (ThreadX: 0..31) |

<a id="ecu-fb"></a>

### `[[fb]]`

A Function Block: the application unit, scheduled on one thread.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | PascalCase, unique (required) |
| `thread` | string | yes | — |  | the [[partition.thread]] it runs on (required) |
| `handler` | array of tables → [`[[fb.handler]]`](#ecu-handler) | yes | — |  | its handlers, at least one |

<a id="ecu-handler"></a>

### `[[fb.handler]]`

A handler: an FB entry point the Loom dispatches.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | identifier (required) |
| `period_ms` | integer | yes | — |  | the period it runs at (ms; the trigger, required) |
| `irq` | string |  | — |  | reserved: an interrupt trigger, refused until it is generated |
| `reads` | array of strings |  | `[]` |  | the signals (and params) it reads |
| `writes` | array of strings |  | `[]` |  | the signals it writes |

<a id="ecu-signal"></a>

### `[[signal]]`

A typed signal from one endpoint to another: a partition, a thread, a bus, or "io".

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | PascalCase; a signal a bus carries takes its DBC name |
| `fields` | table of strings | yes | — |  | field name -> type, the signal's struct |
| `from` | string | yes | — |  | the producer: a partition, thread, bus or "io" |
| `to` | string | yes | — |  | the consumer: a partition, thread, bus or "io" |
| `transport` | string |  | `"double"` | `"double"`, `"triple"`, `"seqlock"`, `"dma"`, `"hw_sem"`, `"mailbox"` | the IOC buffer between partitions (derived for io signals); the hardware ones are target backends, double on host |
| `persist` | string |  | — | `"now"`, `"shutdown"` | keep it in NvM: write-through, or flush at sleep — intent, not tuning (docs/nvm.md) |
| `nvm_id` | integer |  | `0` | 0..65534 | pins the NvM record id (0 = derived; only to resolve a reported collision) |

<a id="ecu-frame"></a>

### `[[frame]]`

Per-frame COM settings. CAN: the DBC message `name` and its tx / rx / E2E / SecOC. eth: a SOME/IP event, its id and signals.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | CAN: the DBC message; eth: the event (PascalCase) |
| `bus` | string | yes | — |  | the [bus.*] it travels on |
| `id` | integer |  | — | 0x8000..0xFFFF | eth: the SOME/IP event id (required there; CAN ids come from the DBC) |
| `signals` | array of strings |  | — |  | eth: its member signals; the payload layout is derived from them |
| `peer` | string |  | — |  | eth: this event's own address:port, when not [someip].peer |
| `tx` | table → [`inline tx`](#ecu-tx) |  | — |  | how it is sent |
| `rx` | table → [`inline rx`](#ecu-rx) |  | — |  | the receive deadline |
| `e2e` | table → [`inline e2e`](#ecu-e2e) |  | — |  | AUTOSAR E2E Profile 1 (the DBC's E2E attributes otherwise) |
| `secoc` | table → [`inline secoc`](#ecu-secoc) |  | — |  | SecOC: AES-CMAC (CAN only) |

<a id="ecu-tx"></a>

### `inline tx`

How a frame is sent (comm/com).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `mode` | string |  | `"cyclic"` | `"cyclic"`, `"event"`, `"mixed"`, `"triggered"` | periodic, on a change, both, or on an explicit trigger (eth: not triggered) |
| `cycle_ms` | integer |  | — |  | the period of a cyclic or mixed frame (ms). Absent: CAN takes the DBC's GenMsgCycleTime, else 100, in multiples of 10; eth takes 100, within 1..1000000 |
| `min_delay_ms` | integer |  | `0` |  | the least gap between two event sends (ms; eth: 0..1000000) |

<a id="ecu-rx"></a>

### `inline rx`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `timeout_ms` | integer |  | `0` | 0..2147483 | the reception deadline (ms; 0 = none); past it the signal status is timeout |

<a id="ecu-e2e"></a>

### `inline e2e`

AUTOSAR E2E Profile 1. Each key defaults to the DBC's E2E attribute; a differing value needs deviates_from_dbc.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `data_id` | integer |  | — | 0x0..0xFFFF | the Data ID mixed into the CRC |
| `crc_pos` | integer |  | — |  | the CRC's byte |
| `counter_pos` | integer |  | — |  | the byte whose low nibble holds the counter |
| `timeout_ms` | integer |  | — | 0..2147483 | rx: the E2E-owned sender-loss timeout (ms; REQ-E2E-002) |
| `deviates_from_dbc` | boolean |  | `false` |  | a field above that differs from the DBC's E2E attributes is deliberate |

<a id="ecu-secoc"></a>

### `inline secoc`

SecOC: a truncated AES-128 CMAC and a freshness value in the frame.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `key` | string |  | — |  | the AES-128 key, 16 space-separated hex bytes (required) |
| `data_id` | integer |  | `0` | 0x0..0xFFFF | the Data ID bound into the MAC |
| `fresh_pos` | integer |  | `0` |  | the freshness value's byte |
| `mac_pos` | integer |  | `0` |  | the MAC's first byte |
| `mac_len` | integer |  | `4` | 1..16 | the truncated MAC's length (bytes) |

<a id="ecu-isotp"></a>

### `[isotp]`

The diagnostic server's ISO 15765-2 connection on CAN (docs/diagnostics.md).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `bus` | string | yes | — |  | the CAN bus ([bus.*] name) the connection runs on |
| `rx_id` | integer | yes | — | 0x0..0x7FF | the CAN id physical requests arrive on (11-bit) |
| `tx_id` | integer | yes | — | 0x0..0x7FF | the CAN id responses are sent on (11-bit) |
| `bs` | integer |  | `0` |  | the block size granted in our Flow Control (0 = the whole message at once) |
| `stmin_ms` | integer |  | `0` |  | the STmin (ms) we ask a sender to keep between consecutive frames |
| `functional_id` | integer |  | — | 0x0..0x7FF | the functional (broadcast) request id, e.g. 0x7DF, single frames only; absent = none |

<a id="ecu-uds"></a>

### `[uds]`

The node's one ISO 14229 diagnostic server: session and security timing, the 0x27 key, the service table.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `s3_ms` | integer |  | `5000` |  | the session timeout back to the default session (ms; 0 = the default) |
| `security_attempts` | integer |  | `3` | 0..255 | wrong 0x27 keys before the lockout (0 = the default) |
| `security_delay_ms` | integer |  | `10000` |  | the 0x27 lockout delay after too many wrong keys (ms; 0 = the default) |
| `security_key` | string |  | — | `"reference"` | "reference" = blobly_net's PUBLIC bench key (a target); absent = the OEM's diag_sa_key_ok |
| `services` | tables by name → [`[uds] services row`](#ecu-uds-service) |  | — |  | the service table, "0xSID" = { ... } ("0x10 02": the [boot] handoff); absent = every service the build performs |

<a id="ecu-uds-service"></a>

### `[uds] services row`

One served service: the sessions it is accepted in and the 0x27 level it needs.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `sessions` | array of strings |  | — | `"default"`, `"extended"`, `"programming"`, `"safety"` | the sessions it is accepted in; absent = the service's default sessions |
| `security` | integer |  | `0` | 0..8 | the 0x27 level that must be unlocked first (0 = none) |

<a id="ecu-doip"></a>

### `[doip]`

The diagnostic server over DoIP (ISO 13400) too — ThreadX target; one parser for this and a system node's `doip` (tools/doipcfg).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `address` | string | yes | — |  | the node's static IPv4 address — a host of its subnet (not its network, broadcast or gateway address — on the default /24: not .0, .1 or .255) |
| `netmask` | string |  | `"255.255.255.0"` | dotted IPv4 | the subnet mask the node is brought up on, application and bootloader alike; contiguous, /1../30 (equal to the eth bus's, where the node has one) |
| `gateway` | string |  | — | dotted IPv4 | the default gateway; inside address/netmask and not its network or broadcast address. Absent = the subnet's first host, (address & netmask) \| 1 |
| `logical_address` | integer | yes | — |  | the entity's logical address (0x0001..0x0DFF or 0x1000..0x7FFF); unique |
| `functional_address` | integer |  | `0xE400` | 0, or 0xE400..0xEFFF | the functional address it also answers |
| `testers` | array of integers |  | — | 0xE00..0xFFF | tester addresses allowed to activate routing (at most 8); absent = any 0x0E00..0x0FFF |
| `activation_types` | array of integers |  | `[0x00]` |  | routing activation types served: 0x00, 0x01, 0xE1..0xFF (at most 4) |
| `initial_inactivity_ms` | integer |  | `2000` | 100..60000 | T_TCP_Initial_Inactivity: time to activate after the TCP connect (ms); <= general_inactivity_ms |
| `general_inactivity_ms` | integer |  | `300000` | 1000..3600000 | T_TCP_General_Inactivity: idle timeout once activated (ms) |
| `announce_count` | integer |  | `3` | 0..10 | A_DoIP_Announce_Num: vehicle announcements at start-up |
| `announce_interval_ms` | integer |  | `500` | 10..10000 | A_DoIP_Announce_Interval (ms); count x interval at most 10000 ms |
| `allow_bench_key` | boolean |  | `false` |  | answer 0x27 with blobly_net's PUBLIC reference key over the network — a bench posture, opted into by name; required (true) when [uds] security_key = "reference" |

<a id="ecu-boot"></a>

### `[boot]`

The node runs behind the bootloader (docs/bootloader.md).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `image_key` | string | yes | — |  | the image-signing PUBLIC key, 64 hex (Ed25519) |
| `session_key` | string | yes | — |  | the 0x29 session PUBLIC key, 64 hex; not the image key |

<a id="ecu-display"></a>

### `[display]`

A local screen: one more ThreadX thread (boards/<board>/display.c, docs/display.md).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `ui` | string | yes | — |  | the node's screen (ui_create, ui_update): a C file relative to the node |

<a id="ecu-did"></a>

### `[[did]]`

A data identifier the server reads (0x22) and may write (0x2E). Its value is ONE of: `ascii` / `bytes` (a constant), `signal` (live), `param` (a coded [[param]]), `param_status`, `tx_saturations`.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `id` | integer | yes | — | 0x0..0xFFFF | the 16-bit data identifier (0 is skipped) |
| `ascii` | string |  | — |  | a constant value as an ASCII string (at most 32 bytes) |
| `bytes` | string |  | — |  | a constant value as space-separated hex bytes (at most 32) |
| `writable` | boolean |  | `false` |  | 0x2E may overwrite the constant's RAM copy with a record of exactly its size (implied by `write`) |
| `signal` | string |  | — |  | a live value: the signal's, refreshed every pass, big-endian at its width; read-only |
| `param` | string |  | — |  | the [[param]] this DID codes (0x2E) and reads back (0x22) |
| `param_status` | boolean |  | `false` |  | one byte per [[param]]: 0 default / 1 coded / 2 reverted |
| `tx_saturations` | boolean |  | `false` |  | the count of sent values saturated to their DBC range since start (u32 BE) |
| `read` | table → [`[[did]] read/write`](#ecu-did-access) |  | — |  | the 0x22 gate; absent = every session, no security |
| `write` | table → [`[[did]] read/write`](#ecu-did-access) |  | — |  | the 0x2E gate (makes the DID writable); absent = every session, no security |

<a id="ecu-did-access"></a>

### `[[did]] read/write`

The sessions and the 0x27 level an access needs.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `session` | array of strings |  | — | `"default"`, `"extended"`, `"programming"`, `"safety"` | the sessions it is allowed in; absent = every session |
| `security` | integer |  | `0` | 0..8 | the 0x27 level that must be unlocked (0 = none) |

<a id="ecu-fault"></a>

### `[[fault]]`

A diagnostic fault: a DTC, the test that sets it and how its results are debounced, confirmed and aged (docs/diagnostics.md §3.3).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | PascalCase, unique; a field of the testing FB's Faults struct |
| `dtc` | integer | yes | — | 0x1..0xFFFFFF | the 3-byte DTC 0x19 reports; unique per server |
| `from` | string |  | — |  | "Fb.handler" — the handler that tests it (or `signal` + `on` for a signal-status fault) |
| `signal` | string |  | — |  | a signal-status fault: the received signal whose rx status the bridge watches |
| `on` | string |  | — | `"timeout"`, `"integrity"`, `"lost"` | a signal-status fault: the rx status that counts as failed |
| `debounce` | table → [`[[fault]] debounce`](#ecu-fault-debounce) |  | — |  | how test results become failed / passed; absent = counter, fail 1, pass 1 |
| `enable` | array of strings |  | `[]` |  | "Signal.field" bool conditions (read by the handler) that must hold for a result to count |
| `confirm` | integer |  | `1` | 1..255 | failed operation cycles to confirm the DTC |
| `aging` | integer |  | `0` | 0..255 | passing cycles before a confirmed DTC ages out (0 = never) |
| `freeze` | array of integers |  | `[]` |  | the snapshot: [[did]] ids captured at the failure, 0x19 04 (at most 4) |
| `priority` | integer |  | `128` | 1..255 | displacement when the snapshot entries are full: 1 (most important) .. 255 |
| `snapshot_id` | integer |  | — |  | retired: refused, with the move to `snapshot_ids` |
| `snapshot_ids` | array of integers |  | — | 0x1..0xFFFE | pins the snapshot's two journal blocks [A, B] (only to resolve a reported collision) |

<a id="ecu-fault-debounce"></a>

### `[[fault]] debounce`

A counter debounce counts results; a time debounce times them. Each kind takes only its own keys.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `kind` | string |  | `"counter"` | `"counter"`, `"time"` | count results, or time them |
| `fail` | integer |  | `1` | 1..65535 | counter: the failed-result threshold |
| `pass` | integer |  | `1` | 1..65535 | counter: the passed-result threshold |
| `fail_ms` | integer |  | — | 1..2147483 | time: how long it keeps failing before it is failed (ms; required) |
| `pass_ms` | integer |  | — | 1..2147483 | time: how long it keeps passing before it is passed (ms; required) |
| `inc` | integer |  | `1` | 1..65535 | counter: the step per failed result |
| `dec` | integer |  | `1` | 1..65535 | counter: the step per passed result |
| `jump` | boolean |  | — |  | counter: reset on a reversal ("N in a row"); default true when fail = 1, else it accumulates |

<a id="ecu-param"></a>

### `[[param]]`

A coded parameter (variant coding): a read-only FB input, coded with 0x2E on its [[did]] and kept in the NvM journal (docs/diagnostics.md §3.4).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | PascalCase; the value type the FBs read |
| `fields` | table of strings | yes | — |  | 1..2 fields, name -> bool / u8 / u16 / u32 / i8 / i16 / i32 |
| `default` | table of integers / booleans | yes | — |  | every field's compiled default, within its range — what an uncoded vehicle runs |
| `range` | tables by name → [`[[param]] range`](#ecu-param-range) |  | — |  | per field, the values it may be coded to; absent = the type's |
| `apply` | string |  | `"next_dispatch"` | `"next_dispatch"`, `"reset"` | when a coded value takes effect: the FB's next dispatch, or the next start |
| `version` | integer |  | `0` | 0..255 | bump when a field's meaning changes but its type does not (stored values revert) |
| `nvm_id` | integer |  | `0` | 0..65534 | pins the journal block (0 = derived; only to resolve a reported collision) |

<a id="ecu-param-range"></a>

### `[[param]] range`

The coded values one field may take (0x2E answers 0x31 outside it).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `min` | integer |  | — |  | the lowest value (default: the type's minimum) |
| `max` | integer |  | — |  | the highest value (default: the type's maximum) |

<a id="ecu-fault-memory"></a>

### `[fault_memory]`

The fault memory as a whole.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `cycle` | string |  | — |  | the operation cycle: a bool "Signal.field", or "power"; absent on a target = NM |
| `entries` | integer |  | — | 1..8 | snapshot entries (default one per fault with `freeze`); fewer = displacement |

<a id="ecu-route"></a>

### `[[route]]`

A gateway route: forward a raw frame, or decode a signal and re-encode it (CAN only).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `signal` | string |  | — |  | a SIGNAL route: decode it on `from`, re-encode it into `to`; absent = a raw frame route |
| `from` | table → [`[[route]] from`](#ecu-route-from) | yes | — |  | the source |
| `to` | table → [`[[route]] to`](#ecu-route-to) | yes | — |  | the destination |

<a id="ecu-route-from"></a>

### `[[route]] from`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `bus` | string | yes | — |  | the source bus |
| `frame` | string | yes | — |  | the DBC frame to forward / decode |

<a id="ecu-route-to"></a>

### `[[route]] to`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `bus` | string | yes | — |  | the destination bus |
| `frame` | string |  | — |  | SIGNAL route: the destination DBC frame to re-encode into (required there) |
| `id` | integer |  | `0` | 0x0..0x1FFFFFFF | FRAME route: the id on the destination bus (0 = keep the source id) |

<a id="ecu-io"></a>

### `[io]`

Physical IO points (docs/io.md), each bound to the [[signal]] of the same name; at most 32.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `core` | integer |  | `0` |  | the io thread's home core; every io signal's partition must be on it |
| `gpio` | array of tables → [`[[io.gpio]]`](#ecu-io-gpio) |  | — |  | digital pins |
| `adc` | array of tables → [`[[io.adc]]`](#ecu-io-adc) |  | — |  | analog inputs (at most 16, one scan sequence) |
| `pwm` | array of tables → [`[[io.pwm]]`](#ecu-io-pwm) |  | — |  | PWM outputs |

<a id="ecu-io-gpio"></a>

### `[[io.gpio]]`

A digital pin: an input (the signal is from "io") or an output (to "io"), one bool field.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | binds the [[signal]] of the same name |
| `pin` | string | yes | — |  | the pad, backend-opaque (e.g. "PB0"); one point per pad |
| `period_ms` | integer | yes | — |  | sample (input) or apply (output) period, ms >= 1, a multiple of the fastest io period |
| `init` | boolean |  | — |  | outputs, REQUIRED there: the level held until the FB first publishes |
| `active_low` | boolean |  | `false` |  | pad polarity: logical true drives the pad LOW |
| `default` | boolean |  | `false` |  | inputs only: the port value before the first real sample |

<a id="ecu-io-adc"></a>

### `[[io.adc]]`

An analog input bound to a u16/u32 [[signal]] from "io".

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | binds a u16/u32 [[signal]] (input only) |
| `pin` | string | yes | — |  | the ADC pad / channel |
| `period_ms` | integer | yes | — |  | the PUBLISH cadence (ms >= 1); the conversion free-runs |
| `default` | integer |  | `0` |  | the count held until the first real sample (within the field type) |

<a id="ecu-io-pwm"></a>

### `[[io.pwm]]`

A PWM output bound to a u16/u32 [[signal]] to "io" carrying duty in permille.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | binds a u16/u32 [[signal]] carrying permille (output only) |
| `pin` | string | yes | — |  | the PWM pad |
| `period_ms` | integer | yes | — |  | the APPLY cadence (ms >= 1) |
| `freq_hz` | integer | yes | — | 1..10000000 | the carrier frequency |
| `init` | integer |  | — | 0..1000 | the duty (permille) before the first publish; required on an output |

<a id="ecu-bulk"></a>

### `[[bulk]]`

A bulk transport pool (docs/bulk-transport.md): a producer/consumer SPSC ring of buffers. Same partition = a per-image arena; different cores = the H755 shared window.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | identifier, unique |
| `producer` | string | yes | — |  | a partition or thread name |
| `consumer` | string | yes | — |  | a partition or thread name |
| `bufsz` | integer | yes | — | 1..1048576 | bytes per buffer, a multiple of 32 |
| `nbuf` | integer | yes | — | 1..1024 | the ring depth |

## system.toml

A system of ECUs (docs/multi-node.md). A system that declares any `[[signal]]`, `[[route]]` or `[[frame]]`, or a node `endpoint`, is DISSOLVED: its nodes author only their internals and `sysgen` lowers the rest into each `gen-<node>.toml`. Otherwise it is COMPOSED from complete per-node ecu.toml files, and syscheck checks them against each other.

<a id="system-sys-top"></a>

### `(top level)`

The sections of a system.toml. At least one bus and one node; `[[signal]]`, `[[frame]]` and `[[route]]` are the dissolution model's.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `bus` | tables by name → [`[bus.*]`](#system-sys-bus) | yes | — |  | the system buses, one [bus.<name>] each; the name is how signals, frames, routes and nodes refer to it |
| `node` | array of tables → [`[[node]]`](#system-sys-node) | yes | — |  | the member ECUs |
| `signal` | array of tables → [`[[signal]]`](#system-sys-signal) |  | — |  | cross-node signals, declared once at system scope (dissolution) |
| `frame` | array of tables → [`[[frame]]`](#system-sys-frame) |  | — |  | SOME/IP events: id, signal set, tx mode and E2E trailer — a someip bus has no DBC to carry them |
| `route` | array of tables → [`[[route]]`](#system-sys-route) |  | — |  | gateway routes between buses (dissolution only) |

<a id="system-sys-bus"></a>

### `[bus.*]`

One system bus: a CAN bus with its DBC, or a SOME/IP segment with its service.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `interface` | string |  | — |  | the physical channel (SocketCAN name, driver channel); unique across buses — one system bus per wire; needed where a member's own [bus.*] (its NM / telemetry bus) is matched to it |
| `kind` | string |  | `"can"` | `"can"`, `"someip"` | the carrier: "can" (DBC frames) or "someip" (a service over Ethernet) |
| `fd` | boolean |  | `false` |  | CAN-FD; in a composed system it must equal each member's own [bus] fd |
| `bitrate` | integer |  | — |  | nominal bitrate in bit/s — informational: syscheck prints it, nothing is generated from it |
| `dbc` | string |  | — |  | the bus's frame contract, relative to system.toml; required on a CAN bus carrying a [[signal]], refused on someip |
| `service` | integer |  | — | 0x0..0xFFFF | someip: the SOME/IP service id (required on a someip bus, refused on CAN) |
| `version` | integer |  | — | 0..255 | someip: the interface version byte (required on a someip bus of a dissolved system, refused on CAN) |
| `nm` | table → [`[bus.*.nm]`](#system-sys-bus-nm) |  | — |  | the bus's NM cluster (CAN only); without it a node's nm id generates a disabled [nm] |

<a id="system-sys-bus-nm"></a>

### `[bus.*.nm]`

An NM cluster: the alive-id range and the timings every member shares. A timing absent (or <= 0) is not lowered, so the node takes loom2v's default.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `peers` | [lo, hi] of integers |  | — |  | [lo, hi] — the cluster's alive CAN ids; a member's alive id is lo + its nm; both at most 0x7FF; required when a member allocates `nm` |
| `msg_cycle_ms` | integer |  | `100` |  | NM message cycle (ms) |
| `timeout_ms` | integer |  | `300` |  | NM timeout (ms) |
| `repeat_ms` | integer |  | `200` |  | NM repeat-message time (ms) |
| `wait_sleep_ms` | integer |  | `150` |  | NM wait-bus-sleep time (ms) |

<a id="system-sys-node"></a>

### `[[node]]`

A member ECU and its system-owned identities.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | identifier, unique; the node's generated config is gen-<name>.toml |
| `ecu` | string | yes | — |  | the node's ecu.toml, relative to system.toml (internals only in a dissolved system) |
| `buses` | array of strings | yes | `[]` |  | the system buses it sits on; more than one CAN bus makes it a [[route]] gateway |
| `nm` | integer |  | — | 0..255 | its NM node id (alive = peers lo + nm); absent = not an NM node; required for a ThreadX member of a bus with an NM cluster |
| `trace` | integer |  | — |  | its trace node id, unique across the system (checked only, not generated) |
| `diag` | table → [`[[node]] diag`](#system-sys-diag) |  | — |  | its ISO-TP diagnostic ids, unique across the system (checked only, not generated); required with `doip` |
| `endpoint` | table → [`[[node]] endpoint`](#system-sys-endpoint) |  | — |  | its network identity: the address SOME/IP and DoIP answer at; required on a someip bus member and on a DoIP entity |
| `doip` | table → [`[[node]] doip`](#system-sys-doip) |  | — |  | the node is a DoIP entity at its endpoint address (lowered into [doip]; dissolved systems only) |

<a id="system-sys-diag"></a>

### `[[node]] diag`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `req` | integer |  | — |  | the diagnostic request CAN id |
| `rsp` | integer |  | — |  | the diagnostic response CAN id |

<a id="system-sys-endpoint"></a>

### `[[node]] endpoint`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `address` | string | yes | — |  | IPv4 dotted quad; unique per segment; a DoIP node needs a host address of its subnet (not its network, broadcast or gateway address — on the default /24: not .0, .1 or .255) |
| `port` | integer |  | — | 1..65535 | the SOME/IP listen port (required on a someip bus; not 13400 on a DoIP node) |
| `netmask` | string |  | `"255.255.255.0"` | dotted IPv4 | the subnet mask the node is brought up on (application and bootloader alike); contiguous, /1../30 |
| `gateway` | string |  | — | dotted IPv4 | the default gateway; inside address/netmask and not its network or broadcast address. Absent = the subnet's first host, (address & netmask) \| 1 |

<a id="system-sys-doip"></a>

### `[[node]] doip`

The DoIP entity and its ISO 13400-2 transport policy (one parser for both files: tools/doipcfg; bounds: comm/doip policy.v).

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `logical` | integer | yes | — |  | the entity's logical address (0x0001..0x0DFF or 0x1000..0x7FFF); unique |
| `functional` | integer |  | `0xE400` | 0xE400..0xEFFF | the functional address it also answers |
| `testers` | array of integers |  | — | 0xE00..0xFFF | tester addresses allowed to activate routing (at most 8); absent = any 0x0E00..0x0FFF |
| `activation_types` | array of integers |  | `[0x00]` |  | routing activation types served: 0x00, 0x01, 0xE1..0xFF (at most 4) |
| `initial_inactivity_ms` | integer |  | `2000` | 100..60000 | T_TCP_Initial_Inactivity: time to activate after the TCP connect (ms); <= general_inactivity_ms |
| `general_inactivity_ms` | integer |  | `300000` | 1000..3600000 | T_TCP_General_Inactivity: idle timeout once activated (ms) |
| `announce_count` | integer |  | `3` | 0..10 | A_DoIP_Announce_Num: vehicle announcements at start-up |
| `announce_interval_ms` | integer |  | `500` | 10..10000 | A_DoIP_Announce_Interval (ms); count x interval at most 10000 ms |
| `allow_bench_key` | boolean |  | `false` |  | answer 0x27 with blobly_net's PUBLIC reference key over the network — a bench posture, opted into by name; required (true) when [uds] security_key = "reference" |

<a id="system-sys-signal"></a>

### `[[signal]]`

A cross-node signal, declared exactly once: who produces it, on which bus and in which frame.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | the signal name; FBs read and write it by this name |
| `fields` | table of strings | yes | — |  | payload fields, name -> scalar type (bool, u8/i8, u16/i16, u32/i32, f32, f64; u64/i64 not on CAN); one value field on CAN |
| `producer` | string | yes | — |  | the node that transmits it; must be on `bus` and have an FB that writes it |
| `bus` | string | yes | — |  | the system bus it rides |
| `frame` | string | yes | — |  | CAN: the DBC message carrying it (sent by the producer); someip: the [[frame]] event carrying it |
| `cycle_ms` | integer |  | `100` |  | CAN tx cadence (ms); signals sharing a frame must agree; refused on someip (the [[frame]] tx says it) |

<a id="system-sys-frame"></a>

### `[[frame]]`

A SOME/IP event on a someip bus: its id, its signals and how it is sent. Lowering copies only what it recognises, so an unknown key is refused.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `name` | string | yes | — |  | the event name; unique per bus |
| `bus` | string | yes | — |  | the someip bus it is on |
| `id` | integer | yes | — | 0x8000..0xFFFF | the SOME/IP event id (bit 15 set; methods own 0x0001..0x7FFF); unique per bus |
| `signals` | array of strings | yes | — |  | its payload signals, in packing order; non-empty, all on the same bus |
| `tx` | table → [`[[frame]] tx`](#system-sys-frame-tx) |  | — |  | how the producer sends it; absent = cyclic every 100 ms |
| `e2e` | table → [`[[frame]] e2e`](#system-sys-frame-e2e) |  | — |  | AUTOSAR E2E Profile 1 trailer |

<a id="system-sys-frame-tx"></a>

### `[[frame]] tx`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `mode` | string |  | `"cyclic"` | `"cyclic"`, `"event"`, `"mixed"` | how the producer sends it: periodically, on a change, or both (the event modes SOME/IP generates) |
| `cycle_ms` | integer |  | `100` | 1..1000000 | the cadence (ms) of a cyclic or mixed event |
| `min_delay_ms` | integer |  | `0` | 0..1000000 | the least gap between two event sends (ms) |

<a id="system-sys-frame-e2e"></a>

### `[[frame]] e2e`

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `data_id` | integer | yes | — | 0x0..0xFFFF | the E2E Data ID (required) |
| `counter_pos` | integer |  | — | 0..65535 | the counter's byte: the appended trailer starts at the derived payload size |
| `crc_pos` | integer |  | — | 0..65535 | the CRC's byte, right after the counter |
| `timeout_ms` | integer |  | — | 1..2147483 | the receiver's sender-loss timeout (ms), longer than the cycle; required unless mode = "event" |

<a id="system-sys-route"></a>

### `[[route]]`

A gateway route between two buses (dissolution only): set exactly one of `frame` / `signal`.

| key | type | required | default | allowed | description |
|---|---|---|---|---|---|
| `gateway` | string | yes | — |  | the node that forwards; it must sit on both buses |
| `frame` | string |  | — |  | a raw frame route: the DBC message forwarded as it is (in both DBCs; not on an FD bus); this or `signal`, exactly one |
| `signal` | string |  | — |  | a signal route: the [[signal]] decoded on `from` and re-encoded on `to`; this or `frame`, exactly one |
| `from` | string | yes | — |  | the source bus |
| `to` | string | yes | — |  | the destination bus |
