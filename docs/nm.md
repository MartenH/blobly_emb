# Network Management (NM)

Coordinated bus sleep/wakeup — lean CAN network management. The bus stays awake as
long as **any** node needs it, and all nodes sleep together once none do. No
central coordinator. The *what* lives in [`requirements/nm.toml`](../requirements/nm.toml)
(`REQ-NM-*`); this is the *design*, and the numbers are config (`[nm.<bus>]`).

> De-AUTOSAR naming: equivalent to CanNm/Nm, generic terms kept. The NM message
> is a plain CAN frame, so it rides the same `can` driver + PDU plumbing.

## State machine

Each node runs an identical state machine ([`comm/nm/nm.v`](../comm/nm/nm.v)),
transport-agnostic and no-alloc:

- While a node **needs** the bus (`request`), it transmits a periodic NM message.
- Hearing **any** NM message (`on_rx`) keeps the local network awake.
- When a node no longer needs the bus (`release`) it stops transmitting but stays
  awake as long as it still hears others.
- When NM traffic stops for `timeout`, a node heads to sleep via a
  `prepare_bus_sleep` grace period, then `bus_sleep`.

```
bus_sleep ──request/on_rx──▶ repeat_message ──(repeat elapsed)──▶ normal_operation
   ▲                                                                    │ release
   │                                                                    ▼
prepare_bus_sleep ◀──(timeout, no rx)── ready_sleep ◀───────────────────┘
   │  (wait_sleep elapses, still no traffic)         ▲ request
   └──────────────▶ bus_sleep                        │ (kept awake by others' rx)
```

`tick(now)` advances the machine and returns `true` when an NM frame should be
sent; `request`/`release`/`on_rx` are the inputs.

| state / transition | realises |
|---|---|
| awake while a node requests the bus | REQ-NM-001 |
| sleep only when all have released | REQ-NM-002 |
| any NM rx keeps the network awake | REQ-NM-003 |
| wake transmits NM messages to announce presence | REQ-NM-004 |
| `prepare_bus_sleep` after `timeout` with no demand | REQ-NM-006 |
| hold `repeat_message` for `repeat_ms` after wake | REQ-NM-007 |
| transmit every `msg_cycle_ms` while awake | REQ-NM-008 |

## The NM frame

Each ECU transmits one small NM message per network, on its own NM CAN-id, to
announce *"I'm here / here's what I need."* (The **NM↔CAN glue** — `comm/nm_can` —
encodes/decodes this frame and drives it on a CAN channel; wire format below.)

```
 byte:  0      1        2   3   4   5   6   7
       ┌────┬────────┬───────────────────────────┐
       │NID │  CBV   │   PN request / user data   │
       └────┴────────┴───────────────────────────┘
```

| byte | field | meaning | realises |
|---|---|---|---|
| 0 | **NID** — source node id | which ECU sent it (1–254) | REQ-NM-011 |
| 1 | **CBV** — control bit vector | flags below | REQ-NM-009/012/013 |
| 2–7 | **PN request** / user data | partial-network bitmask, or app data | REQ-NM-010 |

Control Bit Vector (byte 1):

| bit | name | meaning | realises |
|---|---|---|---|
| 0 | repeat-message request | "everyone re-announce" — resync the cluster | REQ-NM-009 |
| 3 | ready-to-sleep | sender has released the network | REQ-NM-012 |
| 4 | active wakeup | sender actively woke the bus (vs. woke from traffic) | REQ-NM-013 |
| 6 | PN-info present | bytes 2–7 carry a partial-network mask | REQ-NM-010 |
| 1,2,5,7 | reserved | 0 | — |

**Partial networking** (bytes 2–7): each bit is one function cluster ("partial
network"). A set bit means *"I need this PN awake."* A PN sleeps only when **no**
node sets its bit, so a sub-network can power down while the rest stays up.

**Example** — `12 48 05 00 00 00 00 00`: node `0x12`, CBV `0x48` =
ready-to-sleep (bit 3) + PN-info (bit 6), PN mask `0x05` = clusters 0 and 2 →
*"node 18 is willing to sleep but still needs partial networks 0 and 2."*

DBC (the NM message is just a frame; `tx_id 0x400` = decimal 1024):

```
BO_ 1024 NM_Powertrain: 8 ThisECU
 SG_ NM_NodeId : 0|8@1+  (1,0) [0|255] "" Vector__XXX
 SG_ NM_CBV    : 8|8@1+  (1,0) [0|255] "" Vector__XXX
 SG_ NM_PN     : 16|48@1+ (1,0) [0|0]  "" Vector__XXX
```

## Configuration

On a ThreadX target NM is a **ComModule** (docs/com-modules.md): `comm/nm_can.NmModule`
declares two endpoints — `alive` (tx, this node's NM frame) and `peers` (rx, the cluster's
NM traffic as an inclusive **id range**, the first range endpoint) — and `[nm]` in ecu.toml
binds them. loom2v emits the router range arm, the produce drain, and (with `[shell]`) an
`nm` command (`nm` = state, `nm req` / `nm rel` = demand). Timings are **calibration**, not
requirements — a requirement says *"the configured timeout"*, this is where the value lives.

```toml
[nm]
node  = 0x12           # source node id (NID byte)                    REQUIRED
alive = 0x512          # this node's NM id (default: peers base + node)
peers = [0x500, 0x53F] # the cluster's NM id range (inclusive)
pn    = 0              # partial networks this node requests (bitmask) (REQ-NM-010)
request = true         # request the bus from boot (release via `nm rel`)
msg_cycle_ms  = 100    # periodic NM message while awake     (REQ-NM-008)
timeout_ms    = 300    # no-demand time before sleeping      (REQ-NM-006)
repeat_ms     = 200    # repeat-message phase after wake     (REQ-NM-007)
wait_sleep_ms = 150    # prepare_bus_sleep grace period
```

The legacy host path (`nm_can.Link`, a pull-model Transport binding) is configured per
network as `[nm.<bus>]` (node_id/tx_id/rx_lo/rx_hi/...), which `cfg2v` turns into
`gen.nm_<bus>_*` constants — both shapes coexist in one file (`[nm]` scalars are the module
bindings; `[nm.<bus>]` sub-tables are the legacy per-net blocks).

`cfg2v` turns this into `gen.nm_can0_*` constants, so an app builds the binding's
`Config` and the state machine's `Timings` straight from generated values — no
hand-written ids or timers:

```v
mut link := nm_can.Link{
    cfg: nm_can.Config{
        node_id:  gen.nm_can0_node_id
        tx_id:    gen.nm_can0_tx_id
        rx_lo:    gen.nm_can0_rx_lo
        rx_hi:    gen.nm_can0_rx_hi
        pn_local: gen.nm_can0_pn_local
    }
    sm: nm.Nm{ cfg: nm.Timings{
        msg_cycle_us:  gen.nm_can0_msg_cycle_us
        timeout_us:    gen.nm_can0_timeout_us
        repeat_us:     gen.nm_can0_repeat_us
        wait_sleep_us: gen.nm_can0_wait_sleep_us
    } }
}
```

## Verify

```sh
v test comm/nm comm/nm_can   # state machine + the NM↔CAN binding (deterministic)
v run cmd/nm_demo            # two nodes on vcan0: real NM frames, hand-off, sleep
```

The unit tests cover the state machine + timers (`comm/nm/nm_test.v`,
`REQ-NM-001..004, 006..008`), and the frame codec + on-wire binding
(`comm/nm/frame_test.v`, `comm/nm_can/nm_can_test.v`, `REQ-NM-005, 009..013`);
`make trace` links them via `@verifies` tags. The demo drives the **real**
binding over `vcan0` — bring the interface up first with `sudo make vcan` (works
whether vcan is a module or built into the kernel, e.g. WSL2).

## Traceability

| layer | artifact |
|---|---|
| requirements | `requirements/nm.toml` (`REQ-NM-001..013` → `SYS-REQ-NM-001` / `LIFE-002`) |
| design | this document (state machine + frame) |
| config | `ecu.toml` `[nm.<bus>]` (timer values, ids, byte offsets) |
| verification | `comm/nm/nm_test.v` (state machine) + `comm/nm/frame_test.v` (frame codec) + `comm/nm_can/nm_can_test.v` (on-wire binding) — all `@verifies`-linked |

## Not yet

The **NM↔CAN glue** (`comm/nm_can` + `cmd/nm_demo`) and the **Conductor hand-off**
are in place. The lifecycle's sleep/wake is driven by live NM state — the mapping
is one field, `Demand.network_busy = nm.awake()`: while any node needs the bus NM
stays awake and the ECU holds Run; once the cluster times out NM sleeps and the ECU
sleeps; an incoming NM frame wakes NM, which wakes the ECU. Verified across
init→run→sleep→wake in `ecu/handoff_test.v` (REQ-ECU-003/004).

The `comm/nm_can` `Config` + `nm.Timings` are now generated from `ecu.toml` by
`cfg2v` (`gen.nm_<bus>_*`, see Configuration above). Remaining: a full ECU app
example running the Conductor, NM, and partitions together end-to-end.

## NM-gated transmission (REQ-COM-007)

While the state machine reports `bus_sleep`, the node transmits NOTHING: the
generated comm loop computes `nm_up := g_nm.awake()` once per pass and every
producer — cyclic signal tx, telemetry, the trace and shell drains, the
cross-core forwarders — gates on it. NM's own drain is exempt (the state
machine owns its wire behaviour, and nothing needs to go out in sleep anyway:
the wake path is `request()` or a peers-range rx). Two consequences worth
knowing: a shell/trace response caught by sleep stays queued in its module and
goes out after wake (the ISO-TP link does not tick while gated), and
last-is-best semantics mean wake resumes with CURRENT values — no stale-frame
flush. Bench: release → total bus silence within one wait-sleep interval;
peers frame → everything resumes.

