# system_fw — the multi-node P2b FRAME route (raw-PDU firewall)

The frame-route counterpart to [system_gw](../system_gw) (a *signal* route). Two
buses and a gateway that **raw-forwards a whole frame** from one to the other —
the PDU crosses **unchanged**, no decode/re-encode.

```
 (external producer)          gw (H735) = GATEWAY               (external consumers)
   compute bus  ── DiagFrame ──▶  forward DiagFrame raw  ── edge ──▶  DiagFrame
                  PrivateFrame ─▶  ✗ not routed (firewall)
```

A frame route is valid **only because both buses define the frame identically** —
the full-contract compare (`REQ-TOPO-007`) checks id, dlc, format, and every
signal's bit layout / factor / offset / sign / endianness / multiplexing / unit /
value table across the two DBCs. If any of that differed, the raw bits would *mean*
something different on the far bus, so the compare rejects it and tells you to use a
signal route (which re-encodes). It is also a **firewall** (`REQ-TOPO-009`): only
the frame named by a route crosses — `PrivateFrame` on compute never reaches edge.

## Generate + validate

```sh
make gen-system SYSTEM=examples/system_fw/system.toml   # sysgen -> gen-<node>.toml
make syscheck   SYSTEM=examples/system_fw/system.toml   # cross-node + contract compare
```

`gen-gw.toml` gets **two** `[bus.*]` blocks and the lowered raw route:

```toml
[[route]] # GENERATED — raw frame forward, contract-verified (REQ-TOPO-007)
from = { bus = "can0", frame = "DiagFrame" }
to   = { bus = "can1" }
```

## Run it on two vcans

The gateway builds on the host straight from the dissolution (per-bus DBCs merged
by `tools/dbcmerge`, which **dedups** the shared `DiagFrame` — same id on both buses
— and would reject a conflicting redefinition). The generated forwarder recv's on
compute and, **tx-ready gated** (`REQ-TOPO-010` — held + retried, never dropped),
sends on edge in the one comm loop.

```sh
sudo make vcan
make -C examples/system_fw/nodes/gw
examples/system_fw/nodes/gw/bin/app vcan0 vcan1
cansend vcan0 400#DEADBEEF11223344    # DiagFrame  -> appears on vcan1 (400, unchanged)
cansend vcan0 401#0102030405060708    # PrivateFrame -> never appears on vcan1 (firewall)
```

Integration test (`nodes/gw/test/route_firewall.lua`, 2 cases — byte-for-byte
forward + the firewall block):

```sh
cd examples/system_fw/nodes/gw
make test BLOBLY_NET=$HOME/repos/blobly_net
```

## Frame route vs signal route — when to use which

- **Frame route** (here): the same frame exists identically on both buses; forward
  the PDU raw. Cheapest — no codec, no re-protect. A shared broadcast / diagnostic
  frame, or a firewall that passes an allow-list of frames across a boundary.
- **Signal route** ([system_gw](../system_gw)): the buses carry the value in
  *different* frames (different id / layout / rate / scaling), so the gateway
  decodes on one and re-encodes on the other. Transcodes + rate-adapts.

## What is still P2c (not here yet)

- **Extended-id and CAN-FD** raw forwarding — the driver `Frame` path carries
  neither flag yet, so the compare rejects those frames for now.
- The **target multi-bus comm owner** (a channel + Rx-ISR per bus on one core) and
  the H735 FDCAN1↔FDCAN2 bench; cross-core frame PDUs over `xioc`.
