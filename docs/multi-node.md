# Multi-node — a system of ECUs from one description

> Design sketch (2026-07-16). The natural successor to the multi-image emitter
> ([multi-image.md](multi-image.md)): that phase generates an image per **core**
> from one `ecu.toml`; this phase composes a **system of nodes** on shared buses
> from one `system.toml`, generating each node and validating the whole. Nothing
> here is new plumbing — the bus, the DBC, NM, and signed boot are already the
> fabric; multi-node is the **composition + validation** layer over them.

## The thesis: one more rung on the transport ladder

blobly already derives a signal's transport from where its endpoints sit — the
config names *partitions and routing*, never a transport (the multi-image
"SMP-open" directive). Today the ladder is:

| endpoints | derived transport |
|---|---|
| same thread | a plain struct cell (fast path) |
| different threads, same core | an IOC cell (wait-free) |
| different cores, same node | an xioc slot (cross-core SPSC) |
| a bus endpoint (`to = "can0"`) | COM encode + a DBC frame |

Multi-node adds **one rung at the bottom** — endpoints on *different nodes* —
and the honest observation is that **that rung already exists**: a signal a node
transmits and another receives is a CAN frame on the shared bus, defined in the
shared DBC. Cross-node communication is already modelled; it is just spelled
*manually* today (you write `to = "can0"`, author a `[[frame]]`, and put it in
the DBC on both sides). Multi-node makes it **derived and validated**, exactly as
cross-core went from hand-wired duo plumbing to `to = "m4"` → xioc.

So the work is not a new transport. It is: a **system view** that lets the
generator see all the nodes at once, so it can (a) derive each node's
cross-node wiring AND the gateway routing from where producers/consumers sit,
(b) treat the DBC as the system contract every node conforms to, and (c) catch
cross-node bugs at build time — the single-writer rule, id collisions, orphan
receivers — the way it already catches them within a node.

## What is already the fabric (reuse, not invention)

- **The bus + DBC** = the cross-node medium and its contract. A `[[signal]]`
  with a bus endpoint is a frame; the DBC defines the frames once.
- **NM** already speaks *cluster*: `node`, `alive`, and a `peers` id range —
  coordinated sleep/wake across nodes is designed, and the bench already ran two
  nodes with distinct NM ids (H735 = 0x12, H755 = 0x13).
- **Signed boot + UDS** = per-node OTA: each node has diagnostic ids and a
  bootloader; the OTA/diagnostic master addresses each node in turn
  ([bootloader.md](bootloader.md)).
- **The trace dump** already aggregates *cores* on one node into one swimlane;
  aggregating *nodes* is the same move one level up.
- **The multi-image emitter** already emits N images from one config and derives
  per-endpoint transport. Multi-node reuses its emission and extends its endpoint
  resolver with the node rung.

## The new artifact: `system.toml`

A thin top-level file that **composes nodes** — it does not replace each node's
`ecu.toml` (a node still owns its partitions/threads/FBs internally); it names
the **buses** (a real system has ≥2, each with its own DBC), the nodes and which
buses each sits on, the cross-bus **routes**, and each node's identities:

The concrete bench system: the **H735-DK is the system node** — its 3
transceivers, storage, and display make it the gateway, OTA stager, and local
HMI in one board — bridging three buses by purpose:

```toml
[bus.compute]                # H735 <-> H755 (the heavy domain controller)
interface = "can0"           # H735 FDCAN1
fd        = true
bitrate   = 500000
dbc       = "compute.dbc"

[bus.edge]                   # H735 <-> the H723 edge ECUs
interface = "can1"           # H735 FDCAN2
fd        = true
bitrate   = 500000
dbc       = "edge.dbc"

[bus.diag]                   # H735 <-> Linux — diagnostic/OTA, kept OFF the functional buses
interface = "can2"           # H735 FDCAN3
fd        = false
bitrate   = 500000
dbc       = "diag.dbc"

[[node]]
name  = "sysnode"            # the H735-DK: gateway + OTA stager + HMI
ecu   = "nodes/sysnode/ecu.toml"
buses = ["compute", "edge", "diag"]    # all three transceivers
nm    = 0x11
diag  = { req = 0x7A0, rsp = 0x7A8 }
trace = 1

[[node]]
name  = "domain"             # the H755 dual-core domain controller
ecu   = "nodes/domain/ecu.toml"
buses = ["compute"]
nm    = 0x12
diag  = { req = 0x7B0, rsp = 0x7B8 }
trace = 2

[[node]]
name  = "zone_a"             # an H723 edge ECU
ecu   = "nodes/zone_a/ecu.toml"
buses = ["edge"]
nm    = 0x13
diag  = { req = 0x7C0, rsp = 0x7C8 }
trace = 3

# cross-bus routing lives on the gateway (sysnode). Two flavours:
[[route]]                    # FRAME route: forward a PDU unchanged
gateway = "sysnode"
frame   = "VehStatus"        # valid on both DBCs (1:1)
from    = "compute"
to      = "edge"

[[route]]                    # SIGNAL route: re-pack across differing DBCs
gateway = "sysnode"
signal  = "VehicleSpeed"     # decode per compute.dbc, re-encode per edge.dbc
from    = "compute"
to      = "edge"
```

The Linux node (blobly_net) attaches on `diag` — the cloud/dev tier that pushes
campaigns and observes; the H735 sysnode stages the images (its storage) and
reflashes each functional node over its bus. The system runs standalone without
Linux; Linux *adds* OTA + observability when present.

Given this, `make gen` at the system level:

1. **generates each node** (as today, its own image(s) per core), *and*
2. runs the **system-level checks** below, *and*
3. emits a **system manifest** the tooling consumes (nodes, their trace/diag
   ids, the shared DBC) — the observer and the OTA master read this instead of
   being told each node by hand.

## What is generated vs authored (the dissolution)

`system.toml` is the **source** — the generator derives each node's system-facing
wiring *and the routing* from it. The per-node `ecu.toml`'s cross-node half
**dissolves** into `system.toml` (declared once, emitted down), exactly as
`[duo]` dissolved into ordinary signals in the multi-image phase and the
hand-written satellite was absorbed by the emitter. What splits:

**Generated (derived from `system.toml`):**
- each node's **bus wiring** — which signals it tx/rx, the COM encode/decode, the
  DBC frames — declared once at system scope, emitted into each participating node
  (no more "both ends declare the shared signal");
- the **routes** — a cross-node signal whose producer and consumers sit on
  *different buses* has its gateway route **derived** (frame forward if the ids
  are 1:1, signal decode-re-encode if the DBCs differ). You declare the signal and
  who produces/consumes it; the generator places the route on the gateway.
  Explicit `[[route]]` remains only to pin raw-forward / firewall behaviour;
- the **identities** (NM / diag / trace) and the **system manifest**.

**Authored (cannot be derived — it is the logic):**
- each node's **application**: its FBs (the V code) and internal structure
  (partitions, threads, and which FB *produces / consumes* which signal). A node
  keeps a small local description of its own internals + its FB code, so it stays
  developable and unit-testable on its own; it just no longer re-declares the
  cross-node bus contract.

**The generator merges** `system.toml` (the system contract) with each node's
authored internals → that node's complete generated output (ports, loom, the
COM + route bridge). So a signal is declared where it belongs: cross-node ones
once in `system.toml`, node-local ones in the node.

```toml
# in a node's local description: name what it produces/consumes; the SYSTEM
# owns where that goes and how it crosses buses.
[[fb.handler]]
name    = "on_100ms"
reads   = ["VehicleSpeed"]   # a system signal -> generator wires the rx (+ any route)
writes  = ["BrakeCmd"]       # a system signal -> generator wires the tx (+ frame)
```

## Multiple buses and the gateway

A real system is not one bus — it is ≥2 segments (control, body, diagnostic,
zonal), each with **its own DBC**, split for bandwidth, fault isolation, and
security/domain boundaries. That immediately implies a **gateway**: a node on
two or more buses that routes between them. Two routing flavours, and the
per-bus DBC is exactly what forces the distinction:

- **Frame (raw-PDU) routing** — forward a CAN frame from bus A to bus B
  unchanged (same id, same bytes). Transparent and cheap, but only valid when
  the frame means the same thing on both DBCs (a 1:1 id). Also the natural place
  for a **firewall**: route only the allow-listed frames across the boundary.
- **Signal (translating) routing** — decode signals from a frame on bus A *per
  A's DBC*, re-encode them into a *different* frame on bus B *per B's DBC*. This
  is what production gateways do — the two networks have different frame layouts,
  ids, and rates — and it is only expressible because each bus carries its own
  contract. Rate adaptation (a 10 ms signal on A re-emitted at 100 ms on B) lives
  here too.

This is the recognised `route` module (raw-PDU routing / gateway, area ROUTE —
planned). Multi-node gives it a home: a route is declared on the gateway node in
`system.toml`, and the generator emits the forward (frame) or decode-re-encode
(signal) logic into that node's comm loop, alongside its own COM. The gateway is
just another node — the one with the transceivers, storage, and display (the
H735-DK) is the natural gateway *and* OTA stager *and* local HMI, mirroring how a
real in-vehicle system node sits between domains. Its storage stages a whole
campaign's images; its display shows system status; the Linux tier supplies
campaigns over a dedicated diagnostic bus, kept off the functional buses.

Consequences the system view must handle (see the checks below): a signal's
reach is now **bus-scoped** — a consumer only sees producers on *its* bus unless
a route carries the signal across — and NM must decide whether the cluster spans
buses (one sleep domain the gateway bridges) or each bus sleeps independently.

## Node identity — three ids, all cluster-unique

Multi-node's second job (after routing) is **identity**, allocated in
`system.toml` and validated to not collide:

- **NM node id** (+ derived `alive` id, within the cluster `peers` range) — who
  the node is on the wire for coordinated sleep/wake.
- **Diagnostic / boot address** (an ISO-TP req/rsp id pair) — how the OTA or
  diagnostic master reaches *this* node's UDS/boot session to reflash it.
- **Trace node id** — so the observer distinguishes nodes; the current trace id
  is `(core, thread)` and grows a node prefix → `(node, core, thread)`.

Today these are hand-set per `ecu.toml` (and we already hit "give the H735 and
H755 distinct NM ids"). The system view **allocates and cross-checks** them —
the first thing a system gets wrong is two nodes silently sharing an id.

## The real value: system-level validation

The blobly bet is that the generator catches integration bugs at build time. The
same discipline, now *across nodes* — the checks a single `ecu.toml` cannot do
because it cannot see its peers:

- **Single writer, per bus.** On each bus, every signal is *transmitted by
  exactly one node* and *received by at least one* — the IOC single-writer rule
  lifted to the wire. Two transmitters, or none, is a build error.
- **Bus-scoped reachability + routes.** A consumer's need is satisfied by a
  producer *on its bus* OR by a **route** that carries the signal from a bus
  where it is produced. A consumer on bus B with a producer only on bus A and no
  route is a build error — the check that catches "we forgot the gateway rule."
  Every route must reference frames/signals valid on *both* its DBCs.
- **DBC conformance, per bus.** Every node's frame/signal layout matches *that
  bus's* DBC — id, DLC, bit layout, endianness agree on both ends; a signal route
  is checked against the source and destination DBCs independently.
- **Identity uniqueness.** No two nodes share an NM id, a diagnostic address, or
  a trace node id.
- **NM cluster coherence.** All nodes agree on the cluster (`peers` range, the
  sleep/wake parameters) — a node with a mismatched cluster silently never
  sleeps with the others.
- **Reachability (warning).** A produced signal no node consumes, or a rate/tx
  mode mismatch between producer and consumers — surfaced, like unused-signal
  lint, not fatal.

## The payoffs the system view unlocks

- **The observer** (blobly_net): load `system.toml` → the tool knows every node,
  its trace manifest, its diagnostic address. The swimlane aggregates *nodes*
  (each dumps its rings; the observer merges by `(node, core, thread)`), turning
  the per-node flight recorders into one system timeline.
- **OTA / diagnostics master**: the same file tells the master which image goes
  to which node's boot address, and the sequence/compatibility of a campaign —
  the "central node" role from [bootloader.md](bootloader.md), now with a manifest
  to drive it.
- **One source of truth**: the DBC + `system.toml` describe the whole system; a
  node added or a signal moved re-derives every node's wiring and re-runs every
  cross-node check — the multi-image promise, at system scope.

## Phasing (bench rungs, on the hardware to hand)

The target system: the **H735-DK system node** (3 transceivers, storage,
display) as gateway + OTA stager + HMI, bridging a **compute** bus to the **H755**
dual-core domain controller, an **edge** bus to the **2× H723** ECUs, and a
**diag** bus to a **Linux node** (blobly_net) — the cloud/dev/OTA tier. The
functional mesh runs standalone; Linux *adds* campaigns + observability when present.

1. **P1 — sysnode + one node, one bus.** `system.toml` composes the H735 sysnode
   + the H755 on the **compute** bus; the generator emits both and runs the
   per-bus single-writer + id-uniqueness checks. Bench: they exchange a signal
   and sleep together via NM. (Prove composition + checks before the second bus.)
2. **P2 — the gateway across two buses.** Add the **edge** bus (its own DBC) and
   an H723; the H735 sysnode gateways compute<->edge (FDCAN1/FDCAN2) with a frame
   route + a signal route. Bench: a compute-bus signal reaches the H723 only via
   the gateway; the reachability check fails if the route is removed. Real shape.
3. **P3 — the observer.** blobly_net attaches on the **diag** bus, loads
   `system.toml`; the trace swimlane grows node lanes across all buses (aggregate
   every node's dump). One system timeline spanning networks.
4. **P4 — HMI + staged OTA.** The H735 drives its display from routed signals and
   stages images in its storage; Linux pushes a campaign over `diag`, the sysnode
   reflashes each functional node over its bus by diagnostic address — the whole
   in-vehicle-master OTA flow, on the desk.

## Open questions / decisions (for when the phase starts)

- **Routing spelling.** Keep cross-node signals *explicit* (author the DBC frame,
  `to = "veh"`) as the ground truth, and add `to = "<node>"` as **sugar the
  generator lowers** to a matched/auto-allocated DBC frame? Recommended: DBC
  stays the authored contract (it already is); the sugar is optional and must
  resolve to a real frame — never invent a wire format silently.
- **Node ecu.toml vs system.toml ownership.** A node keeps its own `ecu.toml`
  (internal partitions/threads); `system.toml` composes + allocates identity +
  validates. It does *not* absorb the node files — that keeps a node buildable
  and testable alone.
- **Requirements area.** `requirements/topology.toml` (REQ-TOPO-001..006) under
  `SYS-REQ-TOPO-001` — per-bus single-writer, identity-uniqueness, per-bus DBC
  conformance, cluster-coherence, per-node independence, and cross-bus routing —
  each verified by a system-check test the way REQ-COM/NM are.
- **Heterogeneous boards.** Nodes are different parts (H755/H735/H723); the
  boards layer already isolates arch — the system view must not leak board
  assumptions (same rule as multi-image's "no Cortex-M in emission").
- **DBC generation.** Today the DBC is authored and signals conform. For a
  system, consider generating a DBC *skeleton* from the derived cross-node
  signals (author fills scaling/comments), so the frame contract can start from
  the routing instead of being hand-kept in sync. Deferred; conformance-check
  first.
