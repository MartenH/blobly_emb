# Communication stack (COM) — design

How signals get on and off the wire: PDU pack/unpack with **transmission modes**
(periodic / on-change), **PDU routing** (local delivery + gateway forwarding), and
**ISO-TP** segmentation (the basis for diagnostics). All config-driven, generated,
and no-alloc — the same recipe as the rest of blobly.

> Naming: we keep the generic/ISO terms (**COM**, **PDU**, **ISO-TP** = ISO
> 15765-2) and avoid the AUTOSAR module names. The PDU router is the **router**
> (not "PduR"); ISO-TP is **ISO-TP** (not "CanTp"); the scheduler is the **Loom**.

## The layers

```
   FB signals (module sig)                         pure values, physical units
        ▲ unpack            │ pack
        │                   ▼
┌─────────────────────────────────────┐  COM     signal ⇄ PDU; TX modes; RX deadline
│  rx: PDU → signals    tx: signals → PDU │
└─────────────────────────────────────┘
        ▲                   │
        │ deliver           ▼ submit
┌─────────────────────────────────────┐  Router  PDU ↦ destination(s):
│  local→COM │ gateway→bus │ →ISO-TP    │            local (COM), gateway (other bus), TP
└─────────────────────────────────────┘
        ▲                   │
        │ reassembled       ▼ segmented (PDU > one frame)
┌─────────────────────────────────────┐  ISO-TP  SF / FF+CF / FC; BS, STmin, N_* timers
└─────────────────────────────────────┘
        ▲                   │
        │ Frame             ▼ Frame
        driver (CAN / CAN-FD / LIN)  ── bus
```

A **PDU** (Protocol Data Unit) is the unit of routing and transmission. On CAN a
PDU maps 1:1 to a frame (a DBC message); its signal layout comes from the DBC.
Today's generated bus bridge already does the innermost path (rx decode → IOC, IOC
→ encode tx) on a fixed 10 ms tick — COM generalizes that into real TX modes and
RX monitoring, and the router + ISO-TP sit beneath it.

## 1. COM — signal ⇄ PDU, with transmission modes

The DBC gives the *layout*; COM config gives the *behavior* per PDU (frame). A new
`[[frame]]` section maps a DBC message to its COM treatment:

```toml
# rx PDU: unpack to signals, monitor a deadline
[[frame]]
name = "Powertrain"          # DBC message
bus  = "can0"
rx   = { timeout_ms = 200 }  # no frame within 200 ms -> signals go invalid

# tx PDU: send cyclically AND on change (debounced)
[[frame]]
name = "LampFrame"
bus  = "can0"
tx   = { mode = "mixed", cycle_ms = 100, min_delay_ms = 20 }
```

**TX modes** (per tx PDU):

| mode | sends |
|------|-------|
| `cyclic` | every `cycle_ms` |
| `event` | when a contributing signal changes, debounced by `min_delay_ms`, repeated `repeat` × `repeat_ms` |
| `mixed` | both: cyclic heartbeat + immediate on change |
| `triggered` | only on an explicit `trigger` (e.g. from an FB or diag) |

**RX deadline monitoring** (per rx PDU): if no frame arrives within `timeout_ms`,
the unpacked signals are marked invalid (the `valid` field) and/or replaced with an
init value — so an FB's existing `inp.x.valid` check already covers a dropped bus.

This replaces the bridge's unconditional 10 ms send: each PDU runs its own little
TX state machine (last-sent timestamp, change detection, repeat counter), all
generated as a static per-PDU table + a shared stepping routine (no-alloc).

## 2. Router — PDU routing & gateway

Between the driver and COM sits a routing table: for each PDU, where it goes.

```toml
[[route]]                              # gateway: forward a PDU bus→bus, unchanged
from = { bus = "can0", frame = "WheelSpeeds" }
to   = { bus = "can1" }                # optional `id = 0x...` to remap on the way out
```

Three destination kinds:

- **local** → up to COM (unpack to signals). The default for any frame named in a
  `[[frame]]`/signal; what the bridge does for its own signals.
- **gateway** → ✅ **done.** re-transmit the raw PDU on another bus (optionally a
  different id), **never decoded**. The source bus's bridge gets the destination
  channel, and on rx of the routed id forwards the frame directly (drop-free,
  immediate). The `gateway` example forwards `WheelSpeeds` `can0`→`can1`; the test
  injects a raw frame on `can0` and asserts it reappears byte-for-byte on `can1`.
- **TP** → hand the PDU to ISO-TP for reassembly (diagnostics addresses) — already
  done as `[[isotp]]`.

*(Fan-out — one source to several destinations / also-deliver-locally — is a future
extension; today a route is one source → one destination.)*

## 3. ISO-TP — segmented transport (ISO 15765-2)

For PDUs larger than one frame (UDS payloads up to 4095 B classic, more on FD).
Per connection:

```toml
[[isotp]]
name   = "diag"
bus    = "can0"
rx_id  = 0x101      # Request   (DBC)
tx_id  = 0x102      # Response  (DBC)
max_len = 4095      # fixes the reassembly buffer size (no-alloc)
bs      = 8         # flow-control block size
stmin_ms = 0        # min separation time we request
```

State machine per connection:

- **SF** (Single Frame): payload ≤ 7 B (classic) / ≤ 62 B (FD).
- **FF + CF**: First Frame starts a multi-frame transfer; Consecutive Frames carry
  the rest with a 4-bit sequence number.
- **FC** (Flow Control): receiver sends CTS / WAIT / OVFLW with its block size and
  STmin; sender paces CFs accordingly.
- **Timers**: N_As/N_Ar (frame tx/rx), N_Bs/N_Cr (FC/CF wait), N_Cs — timeouts abort
  the transfer.

No-alloc: exactly one fixed `[max_len]u8` reassembly buffer and one TX buffer per
connection, sized at build time. ISO-TP delivers a reassembled PDU up to **UDS**
(below), and blobly_net’s `uds` module drives it in the integration tests (the DBC
already carries `Request`/`Response`).

## 4. UDS — diagnostic services (ISO 14229)

A table-driven, no-alloc `Server` sits above each ISO-TP connection. The bridge
hands it a reassembled request and ships the response it builds. Services:
`0x10` DiagnosticSessionControl, `0x22` ReadDataByIdentifier, `0x2E`
WriteDataByIdentifier, `0x3E` TesterPresent; anything else → negative
(`0x7F sid nrc`).

DataIdentifiers come from `[[did]]` — a constant, a **live signal** (read from the
IOC each tick and encoded big-endian), or a writable RAM cell:

```toml
[[did]]
id = 0xF190; ascii = "BLOBLY-OVERSPEED-01"   # constant (19 B -> multi-frame read)
[[did]]
id = 0xF1A0; signal = "VehicleSpeed"          # live: current km/h via the IOC
[[did]]
id = 0xF1AA; writable = true; bytes = "00 00" # RAM (write then read back)
```

The protocol logic lives in `comm/uds` (unit-tested); the generated bridge fills
the DID table and refreshes signal-backed DIDs. So a tester can read a live bus
signal — or any FB output — straight over diagnostics.

## E2E protection (ISO 26262)

A `[[frame]]` can be **end-to-end protected**: `comm/e2e` stamps an alive counter
and a CRC into the frame on tx and verifies them on rx, so the receiver detects
corruption (CRC), repetition / a stuck sender (counter unchanged), individual lost
frames (counter skip), and loss-of-communication (the rx deadline). A *lost* frame
is still consumed (it's valid and fresh — the skip just marks the gap); *repeated*
and *corrupt* frames are dropped. The generator rejects an `e2e` whose `crc_pos`/
`counter_pos` fall outside the frame DLC.

```toml
[[frame]]
name = "LampFrame"; bus = "can0"
tx   = { mode = "mixed", cycle_ms = 100 }
e2e  = { data_id = 0x10, crc_pos = 1, counter_pos = 2 }  # CRC-8 J1850 + 4-bit counter
```

The bridge stamps **after** the on-change decision (so the ever-changing counter
doesn't defeat send-on-change), and on rx **decodes only if the check passes** — a
bad frame is ignored, and the rx deadline then invalidates the signals. It's a raw
wrap/unwrap on the frame bytes, so it is **independent of the signal transport**.

## SecOC — authenticated messaging (security)

E2E's security sibling: same shape, but the unkeyed CRC becomes a **keyed AES-128
CMAC** and the counter becomes a **freshness value** (anti-replay). E2E stops random
faults (safety); SecOC stops a malicious sender — spoofing, tampering, replay
(ISO-SAE 21434) — because only a key holder can forge the MAC.

```toml
[[frame]]
name = "SecureFrame"; bus = "can0"
tx   = { mode = "cyclic", cycle_ms = 50 }
secoc = { key = "10 11 ... 1f", data_id = 0x20, fresh_pos = 1, mac_pos = 2, mac_len = 4 }
```

On tx the bridge stamps the freshness + a truncated CMAC over `(data_id ‖ payload ‖
freshness)`; on rx it recomputes the MAC (constant-time compare) and checks the
freshness advanced, decoding only an authentic, fresh frame. `comm/secoc` (AES + CMAC)
is unit-tested against the FIPS-197 / RFC 4493 vectors. The wiring is identical to
E2E — the real cost is the crypto and **key + freshness management** (distribution,
sync, monotonicity across resets), which a production system must own.

## No-alloc & generation

Everything new follows the existing split — build-time generators emit static
tables + glue; runtime is fixed-size and lock-free where it crosses cores:

| Generator | Adds |
|-----------|------|
| `dbc2cfg` | already emits decode **and** encode per signal — TP needs no codec |
| `cfg2v`   | per-PDU TX-mode/timeout table, route table, ISO-TP connection table |
| `loom2v`  | the bridge consults those tables: TX stepping, RX deadlines, routing |

Runtime homes (framework, shared): `comm/com/` (TX modes, RX monitoring),
`comm/router/` (dispatch), `comm/isotp/` (segmentation). COM/router run on the
bus-bridge partition; signals still cross to app partitions via the IOC.

## Phased plan

1. **COM TX modes + RX deadline** — ✅ **done**. `[[frame]]` config; the generated
   bridge holds a `com.TxState` per tx PDU (cyclic/event/mixed/triggered) and a
   `com.RxState` per monitored rx PDU. Runtime in `comm/com/` (unit-tested);
   blobly_net asserts cadence + invalidate-on-silence.
2. **Multi-bus + PDU routing** — ✅ **done**. Multi-bus: a signal flows in on one
   bus and out another (the `gateway` example: `can0` → FB → `can1`), one generated
   bridge per bus, `gen.run` taking a channel per bus. Raw-PDU **gateway**: `[[route]]`
   forwards a frame bus→bus untouched (the same example forwards `WheelSpeeds`).
3. **ISO-TP** — ✅ **done**. `[[isotp]]` connections; the bridge holds an
   `isotp.Link` per connection (SF / FF+CF / FC, BlockSize + STmin) in `comm/isotp`
   (unit-tested both directions). Reassembled requests go to a diag handler — for
   now a positive-response echo — and responses are re-segmented. blobly_net's UDS
   client (`:raw`) asserts single- and multi-frame round-trips on the bus.
4. **Diagnostics (UDS)** — ✅ **done**. `comm/uds` table-driven server (session /
   read-DID / write-DID / tester-present + negatives) above each ISO-TP connection;
   `[[did]]` sources (constant / live signal / RAM). blobly_net's `uds` client
   asserts service dispatch + multi-frame DIDs, incl. reading a live signal.

## Testing

blobly_net already covers all of it headless: periodic/event TX is asserted by
watching frame cadence on the bus; routing by checking a frame reappears on the
second bus; ISO-TP/UDS via its `isotp`/`uds` modules against `Request`/`Response`.
