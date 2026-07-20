# gw_signal — a translating (signal-route) gateway

The P2a.2 runtime forwarder (docs/multi-node.md): a **signal route** decodes a DBC
signal from a frame on one bus and **re-encodes** it into a *different* frame on
another bus — the production-gateway pattern where the two networks have different
frame layouts, ids, and rates. Contrast [../gateway](../gateway), which forwards a
frame *raw* (same id, same bytes).

```
 can0 (vcan0)                    the gateway                      can1 (vcan1)
 SrcFrame 0x100  ──▶  decode Speed (bit 0)  ─  re-encode Speed (bit 8)  ──▶  DstFrame 0x200
```

`Speed` sits at **bit 0** in `SrcFrame` but **bit 8** in `DstFrame`, so a raw
byte-forward would put it in the wrong place — only a real decode + re-encode is
correct. The gateway authors just the route; no FB.

```toml
[[route]]
signal = "Speed"
from = { bus = "can0", frame = "SrcFrame" }
to   = { bus = "can1", frame = "DstFrame" }
```

loom2v generates the forwarder in the source bus's COM bridge: on `SrcFrame`,
`dst_frame_speed_set(mut fwd.data, src_frame_speed_phys(rx.data))` then send on
can1 — the per-DBC-message codec fns (from `tools/dbc2cfg`) do the decode/encode.

## Run it (2× vcan)

```sh
sudo make vcan                     # bring up vcan0..vcan7
make -C examples/gw_signal         # gen + host build
./examples/gw_signal/bin/app vcan0 vcan1 &
cansend vcan0 100#3412000000000000 # Speed = 0x1234 at bit 0
candump vcan1                      # -> 200 [8] 00 34 12 00 ...  (Speed re-encoded at bit 8)
```

Verified on vcan (bench). The automated check is `test/route_signal.lua` (the
blobly_net headless Lua runner).

## Scope (P2a.2) — a route *re-frames*, it does not *transcode*

The forwarder decodes and re-encodes across frames and buses, sending the
destination frame **on receipt** of the source. loom2v restricts a signal route to
the cases this faithfully handles (it panics on the rest, which is exactly what the
dissolution rejects at `syscheck`):

- **identical value encoding** — the source and destination `SG_` must share
  length, factor, offset, signedness, and unit. A route moves a signal to a new
  frame / id / bit-position; it does **not** rescale (`12.3@0.1 → 12@1`) or relabel
  units (`100 km/h → 100 mph`).
- **matching cadence, same core, standard ids, no E2E/SecOC, one signal per
  destination frame, single writer.**

What needs the destination frame's own **COM producer** (the routed value wired as
its input, rather than sending on receipt) — the next increment: **value
transcoding**, **rate adaptation** (10 ms → 100 ms), the dest frame's configured
**TX mode**, **validity/freshness** propagation, and **E2E/SecOC** re-protection.
**Cross-core** routes need the `xioc` transport; **frame (raw-PDU)** routing with
the full-contract compare is P2b; the **target multi-bus** comm owner (per-bus
DBCs) is P2c.
