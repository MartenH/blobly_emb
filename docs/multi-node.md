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
generator see all the nodes at once, so it can (a) derive cross-node routing,
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

```toml
[bus.ctrl]                   # control/powertrain segment
interface = "can0"
fd        = true
bitrate   = 500000
dbc       = "ctrl.dbc"       # this bus's frame contract

[bus.body]                   # body/HMI/diagnostic segment
interface = "can1"
fd        = false
bitrate   = 500000
dbc       = "body.dbc"       # a DIFFERENT contract — different frames/layouts

[[node]]
name  = "domain"             # the H755 domain controller — on BOTH buses (gateway)
ecu   = "nodes/domain/ecu.toml"
buses = ["ctrl", "body"]     # 2 CAN peripherals (H7 has FDCAN1/2/3)
nm    = 0x11                 # NM node id (cluster-unique)
diag  = { req = 0x7A0, rsp = 0x7A8 }   # UDS/boot ISO-TP ids (OTA address)
trace = 1                    # trace node id (observer lane group)

[[node]]
name  = "zone_a"             # an H723 edge ECU — control bus only
ecu   = "nodes/zone_a/ecu.toml"
buses = ["ctrl"]
nm    = 0x13
diag  = { req = 0x7C0, rsp = 0x7C8 }
trace = 3

[[node]]
name  = "hmi"                # the H735 with the display — body bus only
ecu   = "nodes/hmi/ecu.toml"
buses = ["body"]
nm    = 0x12
diag  = { req = 0x7B0, rsp = 0x7B8 }
trace = 2

# cross-bus routing lives on the gateway node (domain). Two flavours:
[[route]]                    # FRAME route: forward a PDU unchanged A -> B
gateway = "domain"
frame   = "VehStatus"        # must be a valid frame on both DBCs (1:1)
from    = "ctrl"
to      = "body"

[[route]]                    # SIGNAL route: re-pack across differing DBCs
gateway = "domain"
signal  = "VehicleSpeed"     # decode per ctrl.dbc, re-encode per body.dbc
from    = "ctrl"
to      = "body"
```

Given this, `make gen` at the system level:

1. **generates each node** (as today, its own image(s) per core), *and*
2. runs the **system-level checks** below, *and*
3. emits a **system manifest** the tooling consumes (nodes, their trace/diag
   ids, the shared DBC) — the observer and the OTA master read this instead of
   being told each node by hand.

Each node's `ecu.toml` is unchanged in spirit. The one addition: a signal
endpoint may name **another node's role**, and the generator lowers it to the
bus. Two spellings, pick per taste (this is a design decision, see below):

```toml
# explicit (works today): the author owns the DBC frame
[[signal]]
name = "VehicleSpeed"
from = "app"
to   = "veh"                 # a bus -> a DBC frame the author placed on both nodes

# derived (the sugar multi-node adds): name the consumer's node/role
[[signal]]
name = "VehicleSpeed"
from = "app"
to   = "hmi"                 # 'hmi' is another node -> the generator routes it
                             # over the shared bus, matched to a DBC frame
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
just another node — the most capable one (the H755, with FDCAN1/2/3) is the
natural gateway *and* domain controller, mirroring real zonal/domain designs.

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

The target system: **H755** domain controller, **H735** HMI (its display),
**2× H723** edge/zone ECUs, a **Linux node** (blobly_net) as OTA/diagnostic
master + observer — the peer mesh runs with no master; Linux *adds* observability
and OTA when present.

1. **P1 — two nodes, one bus, one DBC.** `system.toml` composes H755 + one H723
   on the control bus; the generator emits both and runs the per-bus
   single-writer + id-uniqueness checks. Bench: they exchange a signal and sleep
   together via NM. (Prove the composition + checks before adding a second bus.)
2. **P2 — two buses + the gateway.** Add the body bus (its own DBC) and the H735
   HMI on it; the H755 becomes the gateway (FDCAN1 = ctrl, FDCAN2 = body) with a
   frame route and a signal route. Bench: a control-bus signal reaches the HMI
   only via the gateway; the bus-scoped reachability check fails if the route is
   removed. This is the real system shape.
3. **P3 — the observer.** blobly_net loads `system.toml`; the trace swimlane
   grows node lanes across both buses (aggregate every node's dump). One system
   timeline spanning networks.
4. **P4 — the HMI + OTA.** H735 drives its display from routed signals; the Linux
   master reflashes any node by its diagnostic address, reaching nodes on either
   bus through the gateway — the whole OTA flow from the last discussion, on the
   desk.

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
