# Network Management (NM)

Coordinated bus sleep/wakeup — a lean `CanNm`. The goal: the bus stays awake as
long as **any** node needs it, and all nodes sleep together once none do. This
saves power without a central coordinator.

## How it works

Each node runs an identical state machine ([`comm/nm/nm.v`](../comm/nm/nm.v)),
transport-agnostic and no-alloc:

- While a node **needs** the bus (`request`), it transmits a periodic NM message.
- Hearing **any** NM message (`on_rx`) keeps the local network awake.
- When a node no longer needs the bus (`release`) it stops transmitting but stays
  awake as long as it still hears others.
- When NM traffic stops for `timeout`, a node heads to sleep via a
  `prepare_bus_sleep` grace period, then `bus_sleep`.

### States

```
bus_sleep ──request/on_rx──▶ repeat_message ──(repeat elapsed)──▶ normal_operation
   ▲                                                                    │ release
   │                                                                    ▼
prepare_bus_sleep ◀──(timeout, no rx)── ready_sleep ◀───────────────────┘
   │  (wait_sleep elapses, still no traffic)         ▲ request
   └──────────────▶ bus_sleep                        │ (kept awake by others' rx)
```

`tick(now)` advances the machine and returns `true` when an NM frame should be
sent; `request`/`release`/`on_rx` are the inputs. The partition glue turns
`tick()==true` into a CAN frame on the NM id and calls `on_rx` on reception.

## Configuration

Per network, in `config/ecu.toml`:

```toml
[nm.can0]
node_id       = 7
tx_id         = 0x400
msg_cycle_ms  = 100
timeout_ms    = 300
repeat_ms     = 200
wait_sleep_ms = 150
```

`cfg2v` generates `gen.nm_can0_*` constants (ms → µs) consumed at runtime.

## Verify

```sh
v test comm/nm          # state-machine unit tests (deterministic)
v run cmd/nm_demo        # two nodes A/B: hand-off then coordinated sleep
```

The demo shows the bus AWAKE through `A → hand-off → B`, then both nodes release
and the bus reaches `asleep`.

## Not yet

The NM↔CAN partition glue (sending the NM frame, mapping the NM id range on rx)
and integrating NM request/release with the application are follow-ups. This PR
lands the state machine + config + codegen + tests + simulation.
