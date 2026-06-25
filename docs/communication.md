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
to   = { bus = "can1", frame = "WheelSpeeds" }

[[route]]                              # fan-out: forward AND deliver locally
from = { bus = "can0", frame = "BrakeStatus" }
to   = [ { bus = "can1" }, { local = true } ]
```

Three destination kinds:

- **local** → up to COM (unpack to signals). The default for any frame named in a
  `[[frame]]`/signal; what the bridge does today.
- **gateway** → re-transmit the raw PDU on another bus (optionally a different id),
  no unpack — needs a ≥2-bus example.
- **TP** → hand the PDU to ISO-TP for reassembly (diagnostics addresses).

Generated as a static dispatch table `{src bus+id → [dest]}`; the bridge’s rx path
consults it instead of hard-coding "decode locally".

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
connection, sized at build time. ISO-TP delivers a reassembled PDU up to **diag
(UDS)** — a separate layer/PR — and cantester’s `isotp`/`uds` modules drive it in
the integration tests (the DBC already carries `Request`/`Response`).

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
   cantester asserts cadence + invalidate-on-silence.
2. **PDU routing / gateway** — `[[route]]` + a 2-bus example (e.g. `can0`↔`can1`),
   forwarding a frame and proving the dispatch table.
3. **ISO-TP** — ✅ **done**. `[[isotp]]` connections; the bridge holds an
   `isotp.Link` per connection (SF / FF+CF / FC, BlockSize + STmin) in `comm/isotp`
   (unit-tested both directions). Reassembled requests go to a diag handler — for
   now a positive-response echo — and responses are re-segmented. cantester's UDS
   client (`:raw`) asserts single- and multi-frame round-trips on the bus.
4. **Diagnostics (UDS)** on top of ISO-TP — sessions, services, `Request`/`Response`
   — replaces the echo handler; its own doc, tested with cantester's `uds`. *(next)*

## Testing

cantester_v already covers all of it headless: periodic/event TX is asserted by
watching frame cadence on the bus; routing by checking a frame reappears on the
second bus; ISO-TP/UDS via its `isotp`/`uds` modules against `Request`/`Response`.
