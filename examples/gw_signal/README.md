# gw_signal — a translating (signal-route) gateway

The P2a.2b runtime forwarder (docs/multi-node.md): a **signal route** decodes a DBC
signal from a frame on one bus and routes its value through the **destination
frame's own COM producer** on another bus — the production-gateway pattern where
the two networks have different frame layouts, ids, scaling, and rates. Contrast
[../gateway](../gateway), which forwards a frame *raw* (same id, same bytes).

```
 can0 (vcan0)                         the gateway                        can1 (vcan1)
 SrcFrame 0x100  ──▶  decode Speed (bit 0, ×0.1) ─ store ─ producer re-emits @100 ms ──▶  DstFrame 0x200
   @20 ms                                          (Speed bit 8, ×1)                        @100 ms
```

`Speed` is `0.1 km/h`-scaled at **bit 0** in `SrcFrame` (20 ms) but `1 km/h` at
**bit 8** in `DstFrame` (100 ms). The route **transcodes** the value (×0.1 → ×1,
so 10.0 km/h stays 10.0 km/h) and **rate-adapts** (a 20 ms source re-emitted at
the destination's 100 ms cadence). The gateway authors just the route; no FB.

```toml
[[route]]
signal = "Speed"
from = { bus = "can0", frame = "SrcFrame" }
to   = { bus = "can1", frame = "DstFrame" }
```

loom2v generates, in the source bus's bridge: on rx of `SrcFrame`, decode the
**physical** value (`src_frame_speed_phys`) and store it with a freshness stamp;
then, each tick, a **producer** composes `DstFrame` (`dst_frame_speed_set`) and
re-emits it per the destination frame's `com.TxState` (cadence + TX mode), gated on
`tx_ready`. A signal not yet received — or stale beyond its source deadline —
suppresses the destination frame, so a downstream receiver detects the loss.

## Run it (2× vcan)

```sh
sudo make vcan                     # bring up vcan0..vcan7
make -C examples/gw_signal         # gen + host build
./examples/gw_signal/bin/app vcan0 vcan1 &
cansend vcan0 100#6400000000000000 # Speed raw 100 = 10.0 km/h (×0.1) at bit 0
candump vcan1                      # -> 200 [8] 00 0A 00 ...  (raw 10 = 10.0 km/h ×1, at bit 8), @100 ms
```

Verified on vcan. The automated check is `test/route_signal.lua` (the blobly_net
headless Lua runner).

## What it exercises (P2a.2b)

The value routes through the **destination frame's producer**, so the route:

- **transcodes** — decode to physical on the source, re-encode to physical on the
  destination (differing factor / offset), rather than a raw copy;
- **rate-adapts** — the destination producer re-emits at its own cadence /
  **TX mode**, sampling the latest value (a fast source → a slow destination);
- **propagates validity** — a source that never arrives, or goes stale beyond its
  deadline, suppresses the destination frame;
- **composes** — several routes into one destination frame fill it together (every
  `SG_` in a routed frame must be routed).

Still ahead: **E2E/SecOC** re-protection on a routed frame (rejected for now);
**cross-core** routes need the `xioc` transport; **frame (raw-PDU)** routing with
the full-contract compare is P2b; the **target multi-bus** comm owner (per-bus
DBCs) is P2c.
