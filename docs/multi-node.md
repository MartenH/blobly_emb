# Multi-node — a system of ECUs from one description

> Design sketch (2026-07-16). The natural successor to the multi-image emitter
> ([multi-image.md](multi-image.md)): that phase generates an image per **core**
> from one `ecu.toml`; this phase composes a **system of nodes** on a shared bus
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
the nodes, the shared bus(es) and DBC, and each node's identities:

```toml
[import]
dbc = "system.dbc"          # the ONE cross-node contract

[bus.veh]                    # the shared vehicle bus, defined ONCE
interface = "can0"
fd        = true
bitrate   = 500000

[[node]]
name  = "domain"             # the H755 domain controller
ecu   = "nodes/domain/ecu.toml"
nm    = 0x11                 # NM node id (cluster-unique)
diag  = { req = 0x7A0, rsp = 0x7A8 }   # UDS/boot ISO-TP ids (OTA address)
trace = 1                    # trace node id (observer lane group)

[[node]]
name  = "hmi"                # the H735 with the display
ecu   = "nodes/hmi/ecu.toml"
nm    = 0x12
diag  = { req = 0x7B0, rsp = 0x7B8 }
trace = 2

[[node]]
name  = "zone_a"             # an H723 edge ECU
ecu   = "nodes/zone_a/ecu.toml"
nm    = 0x13
diag  = { req = 0x7C0, rsp = 0x7C8 }
trace = 3
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

- **Single writer, across nodes.** Every cross-node signal is *transmitted by
  exactly one node* and *received by at least one* — the IOC single-writer rule
  lifted to the bus. A signal two nodes both transmit, or that nobody produces,
  is a build error (today: an undetected runtime surprise).
- **DBC conformance.** Every node's frame/signal layout matches the shared DBC —
  id, DLC, bit layout, endianness agree on both ends. (The DBC is the contract;
  the check enforces it.)
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

1. **P1 — two nodes, one bus, shared DBC.** `system.toml` composes H755 + one
   H723; the generator emits both and runs the tx/rx-pairing + id-uniqueness
   checks. Bench: the two nodes exchange a signal and sleep together via NM.
2. **P2 — the observer.** blobly_net loads `system.toml`; the trace swimlane
   grows node lanes (aggregate the two nodes' dumps). One system timeline.
3. **P3 — the HMI node.** H735 example: read bus signals, drive the display. A
   new example (board support exists; the LCD driver is the new bit).
4. **P4 — OTA in miniature.** The Linux master reflashes any node by its
   diagnostic address (the P5 signed boot per node) — the whole OTA flow from
   the last discussion, on the desk.

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
- **Requirements area.** A new `requirements/topology.toml` (REQ-TOPO-\*) under a
  `SYS-REQ-TOPO-001` — the cross-node single-writer, identity-uniqueness, DBC
  conformance, and cluster-coherence guarantees each get a requirement, verified
  by a system-check test the way REQ-COM/NM are.
- **Heterogeneous boards.** Nodes are different parts (H755/H735/H723); the
  boards layer already isolates arch — the system view must not leak board
  assumptions (same rule as multi-image's "no Cortex-M in emission").
- **DBC generation.** Today the DBC is authored and signals conform. For a
  system, consider generating a DBC *skeleton* from the derived cross-node
  signals (author fills scaling/comments), so the frame contract can start from
  the routing instead of being hand-kept in sync. Deferred; conformance-check
  first.
