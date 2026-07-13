# How do I add a CAN frame?

A frame is a DBC message plus, optionally, per-PDU COM behaviour in `[[frame]]`. The DBC
owns the wire format (id, DLC, signal layout); `ecu.toml` owns the behaviour (tx mode,
timing).

## 1. Add the message to the example's `bus.dbc`

```
BO_ 513 M4LoadFrame: 8 SUT
 SG_ M4Count : 0|32@1+ (1,0) [0|4294967295] "" Tester
 SG_ M4Acc : 32|32@1+ (1,0) [0|4294967295] "" Tester
```

- `513` = decimal CAN id (0x201). Keep it 11-bit for the target FDCAN backend.
- Signal names here are what `[[signal]]` declarations resolve against.
- The lean target codec wants unsigned little-endian u32 fields at 32-bit offsets,
  factor 1, offset 0 (see [add-a-signal.md](add-a-signal.md) for the full rules).

## 2. Give it COM behaviour

```toml
[[frame]]
name = "M4LoadFrame"           # the DBC message name
bus  = "can0"
tx   = { mode = "cyclic", cycle_ms = 100 }
```

- The ThreadX comm loop generates **cyclic** tx only (event/mixed are host-bridge
  features for now). No `[[frame]]` block → a tx signal defaults to cyclic 100 ms.
- The frame is actually transmitted when some `[[signal]]` with a `to = "<bus>"`
  endpoint rides it — a `[[frame]]` alone sends nothing.
- Rx needs no `[[frame]]`: declare a `from = "<bus>"` signal and the comm loop routes
  the id to the reading FB's IOC cell.

Host-bridge examples additionally understand `rx = { timeout_ms }`, `e2e`, and `secoc`
keys ([../communication.md](../communication.md)); the ThreadX target rejects them until
those land on-target.

## 3. Reserved id ranges to avoid

The platform modules bind their own frames (all configurable, these are the conventions
used across the examples): telemetry 0x7E0/0x7E1, trace 0x7E2–0x7E6, shell 0x7F0–0x7F2,
NM `peers` range (e.g. 0x500–0x53F). Pick app ids clear of whatever your `[telemetry]`,
`[trace]`, `[shell]`, `[nm]` blocks bind.

## Verify

```sh
make gen && make && make flash
candump can0                       # frame appears at its cycle time
# check the PAYLOAD advances as the app computes, not merely that the id shows up
```
