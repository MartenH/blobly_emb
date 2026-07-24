# How do I gateway a frame or a signal?

A **route** forwards traffic from one bus to another. There are exactly two kinds, and
picking the wrong one is the usual mistake:

| | **frame route** | **signal route** |
|---|---|---|
| declares | `from`/`to` only | `signal = "..."` as well |
| does | re-transmits the raw PDU, **never decoded** | decodes on the source, **re-encodes** into the destination frame |
| requires | the payload to mean the same thing on both buses | the signal to exist (by name) in a source **and** a destination frame — *layout/scaling* may then differ freely **within the codec's limits**: no multiplexed signals, no big-endian (Motorola) layouts, ≤52-bit width (the value transits an f64); incompatible units, value tables, or ranges are also rejected at generation |
| costs | almost nothing | a decode + encode per frame |
| example | [`gateway`](../../examples/gateway), [`gw_extid`](../../examples/gw_extid) | [`gw_signal`](../../examples/gw_signal), [`gw_e2e`](../../examples/gw_e2e), [`gw_srcverify`](../../examples/gw_srcverify) |

**The rule:** forward the frame when the bytes are already correct for the destination.
Route the signal when they are not.

## 1. Frame route — forward the PDU untouched

```toml
[[route]]
from = { bus = "can0", frame = "WheelSpeeds" }
to   = { bus = "can1" }              # optional `id = 0x...` to remap on the way out
```

The source bus's bridge is handed the destination channel and forwards on rx —
immediate, with no decode in the path. `gateway`'s test injects a raw frame on `can0` and
asserts it reappears **byte-for-byte** on `can1`. Under backpressure it is
**freshest-wins, not drop-free**: while the destination is not ready, the bridge holds
*one* retry frame per route and each new arrival overwrites it — right for cyclic state,
wrong for event traffic whose every frame must survive. And there is **no lossless
generated alternative across buses today**: raw-routing an ISO-TP conversation's CAN ids
rides this same freshest-wins slot (one lost CF and the transfer dies), and the generated
`[[isotp]]` connection terminates locally at UDS — a cross-bus ISO-TP proxy that
terminates one link and re-originates the other is hand-written module work.

Use it when:

- **the id and layout are identical on both buses** (the 1:1 case),
- you are **firewalling** — deciding what may cross, not transforming it,
- the frame is **opaque to this ECU** (you have no DBC for its contents and do not want one),
- you need the **lowest possible added latency**.

29-bit ids forward correctly (`gw_extid`); the ext flag rides with the frame.

## 2. Signal route — decode and re-encode

```toml
[[route]]
signal = "Speed"
from = { bus = "can0", frame = "SrcFrame" }
to   = { bus = "can1", frame = "DstFrame" }
```

Use it when **the bytes are not already correct**:

- **The DBCs differ.** In `gw_signal`, `Speed` sits at bit 0 in the source frame and bit 8
  in the destination — a raw forward would corrupt it. Only a real decode + re-encode is
  right.
- **The destination is protected.** In `gw_e2e`, the destination frame carries E2E (or
  SecOC); the producer **re-protects** the composed frame — fresh counter and CRC each
  cycle — so a downstream receiver's check passes. Forwarding raw bytes into a protected
  frame produces a frame that fails its own CRC.
- **The source is protected and you must not trust it blindly.** `gw_srcverify` decodes
  only if the source's E2E check passes: a tampered frame never reaches the far bus, and
  once the source goes stale the destination is suppressed.
- **You are changing the contract** — different scaling, a different frame layout, or
  fanning one signal into a frame that carries others.

A routed signal must exist in the destination DBC, and unambiguously: if it appears in
more than one destination frame, generation fails rather than guessing (REQ-TOPO-006).

## 3. Which bus owns the route

On a single ECU, `[[route]]` lives in that node's `ecu.toml` (above). In a **system** of
nodes it lives in `system.toml` and names the gateway node:

```toml
[[route]]
gateway = "sysnode"
frame   = "VehStatus"        # or: signal = "VehicleSpeed"
from    = "compute"
to      = "edge"
```

The route must be **explicit**: when a cross-node signal's producer and consumers sit on
different buses and no `[[route]]` names the gateway, `syscheck` reports the consumer as
unreachable — the generator does **not** derive a route from the topology (deriving one is
a possible future; today omitting the route is an error, not a default). See
[system-from-nodes.md](system-from-nodes.md) and [../multi-node.md](../multi-node.md).

## 4. Verify it

Every example above has a `test/` that drives it over two vcans:

```sh
sudo make vcan                       # once — brings up vcan0/vcan1
make -C examples/gw_signal           # generate + host build
./examples/gw_signal/bin/app vcan0 vcan1
```

## Buses on different cores

A **signal route** may cross cores: the decoded value (one f64) rides an IOC channel
between the two comm owners — the source bridge publishes on rx, the *destination* bridge
composes and transmits on its own channel, and freshness is stamped on the destination
side so no clock ever crosses the boundary (REQ-TOPO-010). Declare it exactly like a
same-core route; the generator derives the crossing from `[bus.*] core`. Worked example:
[`gw_xcore`](../../examples/gw_xcore).

A **frame route** may not: a raw PDU does not fit a signal cell, and carrying it whole is
the [bulk transport](../bulk-transport.md)'s job — generation fails with exactly that
message. Route the signal, or keep both buses on one core.

## Limits worth knowing

- One `[[route]]` names **one destination** — but several routes may share a source
  frame, and the generator emits an independent forward (with its own retry slot) per
  route, so fan-out to several buses is just several routes. Forward *and* deliver
  locally also works: after the route blocks, the received frame still runs the normal
  COM decode for this node's own consumers. **Unprotected sources only**: an E2E/SecOC
  source frame allows exactly one verifying consumer — a second signal route (or local
  COM delivery beside a route) would advance the verification counter twice per frame,
  so generation rejects those combinations.
- A frame route never decodes, so it cannot check E2E on the way through — that is what
  `gw_srcverify` (a signal route) is for.
- Routes are CAN machinery. A route touching an eth bus is rejected at generation.
- Routes run in the **host/sim comm bridges** today. On a `kind = "threadx"` target the
  comm thread has no route forwarder yet and generation rejects any route — the "target
  multi-bus comm owner" roadmap item is exactly that gap.

Design rationale: [../communication.md](../communication.md) §2 (router & gateway).
