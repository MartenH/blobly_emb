# SOME/IP — signals and services over Ethernet

> Status: DESIGN (2026-07-19). Requirements: `requirements/net.toml`
> REQ-NET-013..017 (draft). Builds on docs/net.md — link/UDP/TCP/DoIP are
> bench-verified on the H735-DK, so this phase starts on a proven substrate.
> Nothing here is built; this page is the shape to argue with.
> (AUTOSAR-comparison note: this is the territory `ara::com` + the SOME/IP
> transformer occupy — blobly's version is the existing COM tables over a UDP
> socket plus a 16-byte standard header. No service middleware, no ARXML.)

## The one idea

A SOME/IP event is a **frame on an eth bus**. Same `[[signal]]`/`[[frame]]`
declarations, a payload layout fixed at build time, same frame→module routing
(docs/com-modules.md) — the only new things are a bus kind whose frames travel
as UDP datagrams instead of CAN frames, and the standard 16-byte SOME/IP header
in front of the payload so the wire is legible to commodity tooling (Wireshark
dissects it, scapy generates it, blobly_net's planned `modules/someip` speaks
it). SOME/IP is adopted as a **wire format, not a middleware**: no service
discovery on the target, no dynamic types, no broker, no agent. Rejected
alternatives: DDS/XRCE (discovery + QoS caches + an agent process — alloc-shaped
machinery a closed, build-time-configured network doesn't need; even ROS 2
concluded real DDS doesn't fit MCUs), zenoh/MQTT-SN (router/broker topology),
IEEE 1722 ACF-CAN (L2, hostile to a sim-first socket workflow), and a bespoke
raw-UDP framing — the runner-up, cheaper by exactly one header, which is too
little savings to give up the dissector and the standard vocabulary.

This is the same absorption move the model keeps making: bus endpoints → COM
codec, cross-core endpoints → xioc slots, IO points → signal endpoints
(docs/io.md). Ethernet transport is config, not a parallel universe.

## The config surface (ecu.toml)

```toml
# An eth bus: frames on it are SOME/IP messages in UDP datagrams.
# interface — host sim: the local address to bind; target: the NetX IP instance.
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"
core      = 0

# The service identity + static endpoints. ONE eth bus (and one [someip]
# block) per image for now — ecucheck enforces the pair; a keyed
# [someip.<bus>] table is the generalisation if a second eth bus ever exists.
# version — the interface version carried in every header; explicitly managed,
# bumped on a breaking layout change (it is config next to the frames, so the
# bump is reviewed in the same diff that changes the layout).
# peer — where events/responses go and where requests come from. STATIC: no SD.
[someip]
bus      = "eth0"
service  = 0x0100
instance = 0x0001
version  = 1
port     = 30490
peer     = "192.168.0.10:30490"

# Frames on an eth bus reuse the id field as the SOME/IP method/event id.
# Bit 15 classifies the id's ROLE, not its direction: set = event/notification
# (tx = we publish it, rx = we consume one), clear = method (P3
# request/response). signals declares membership — the eth path has no DBC;
# the layout is derived from this list (next section).
[[frame]]
name    = "BenchTelem"
bus     = "eth0"
id      = 0x8001
signals = ["CpuLoad", "BenchCounters"]
tx      = { mode = "cyclic", cycle_ms = 100 }

# Module-owned frames don't use [[frame]] at all: a ComModule block binds its
# endpoints to eth event ids exactly as it binds CAN ids (docs/com-modules.md
# — ids appear once, in the module block; the module owns its payload bytes).
# This is how the P1 trace/telemetry egress is configured:
[trace]
bus    = "eth0"
record = 0x8002
```

## Payload layout without a DBC

On CAN, signal→frame membership and the bit layout come from the imported DBC;
an eth frame gets neither, so the config must supply both. Membership is the
frame's `signals` list. The layout is **derived, never authored**: fields
packed in signal-list order, little-endian, each field at its natural width,
byte-aligned, no other padding — deterministic from the `[[signal]]` `fields`
declarations alone, so there are no hand-written offsets to drift. The
generator emits the resulting layout table twice: into `gen/` for the image,
and into the trace manifest so the host side (blobly_net) decodes from the
same source of truth. Extending the DBC dialect to describe eth frames was
considered and rejected: it would put eth layout in a CAN-shaped artifact and
split the config across two files for no interop gain — the payload is
deployment-defined either way (see the wire subset below).

What ecucheck adds (same rule family as the io bindings, docs/io.md):

- an eth-bus frame id must fit 16 bits, and its bit-15 class must match the
  frame's role: event ids (bit 15 set) may be tx (we publish) or rx (we
  consume a peer's notification) — direction does NOT decide the class;
  method ids (bit 15 clear) exist only once the RPC phase does, and pair
  rx request with tx response;
- a `[[frame]]` on an eth bus is a SIGNAL frame: its `signals` list must be
  present, non-empty, and name signals whose bus endpoint is this frame's bus,
  and a signal may ride exactly one frame. One direction per frame: a tx
  frame's signals all have `to = <bus>`, an rx frame's all have
  `from = <bus>` — a mixed frame would make the bridge a second writer on a
  channel it doesn't own (the SPSC invariant), so it is rejected, not
  supported. Module frames are NOT `[[frame]]` entries — a ComModule block
  binds its endpoints to eth ids directly (the `[trace]` example above);
- eth ids are unique across EVERYTHING that binds one — signal frames and
  every module endpoint of every module — with exactly one modeled exception:
  a request/response endpoint pair shares its method id, disambiguated by
  message type. Two rx bindings on one id would route to only one of them;
  two tx bindings would give peers one id with two payload schemas;
- every field of an eth-frame signal must be a fixed-width scalar (`bool`,
  `u8`..`u64`, `i8`..`i64`, `f32`/`f64`) — the layout derivation has no
  meaning for strings, slices, or anything heap-shaped, and the no-alloc
  invariant forbids them in generated runtime code anyway;
- `service` and `instance` must fit 16 bits, `version` 8 bits, `port` is
  1..65535, and `peer` must parse as an address:port pair — narrowing happens
  in the header packing, so an over-wide value would otherwise silently
  collide instead of failing the build;
- the derived payload must fit the SHARED PDU bound — `comm.com`'s 64-byte
  `max_pdu`, which the whole codec/router path is sized for — not merely the
  datagram. A wider eth PDU type is its own later rung (open question below),
  never a silent relaxation; segmentation (SOME/IP-TP) stays out of scope, so
  an oversize frame is a config error, not a runtime surprise;
- `[someip]` requires the (single) `kind = "eth"` bus; a `[someip]` block
  without eth frames, eth frames without a `[someip]` block, or a second eth
  bus are all errors — half-configured transports fail loud at build time.

## The wire subset

The 16-byte header, big-endian on the wire as the standard requires:

| Field | Size | blobly binding |
|---|---|---|
| Message ID | 32 | `service` (high 16) + frame `id` (low 16) |
| Length | 32 | 8 + payload length (bytes after this field) |
| Request ID | 32 | events: client 0x0000 + a per-frame session counter (wraps 1..0xFFFF — receivers get loss detection for free); requests: echoed into the response |
| Protocol version | 8 | 0x01 |
| Interface version | 8 | the configured `[someip] version`, explicitly managed — bumped in the same reviewed diff that breaks the layout. (A truncated config hash was considered and rejected: 1/256 silent collisions, and unrelated table edits would churn the version. Strict build-identity checking is host-side — the oracle compares the layout table the trace manifest carries.) |
| Message type | 8 | P1: NOTIFICATION (0x02). P3 adds REQUEST (0x00) / RESPONSE (0x80) / ERROR (0x81) |
| Return code | 8 | 0x00; P3 error paths use the standard codes |

The **payload** is NOT the CAN codec's output — the DBC codec packs signal
*values* at DBC bit positions with scaling and synthesizes rx-side fields; the
eth payload is the **derived layout** above (raw declared fields, declaration
order, little-endian, natural widths), a small generated eth codec of its own.
For a module-bound frame the payload is the module's own bytes, exactly as on
CAN. Little-endian is a declared deviation from AUTOSAR's default big-endian
payload serialization: SOME/IP the wire standard does not mandate payload
endianness (it is deployment-defined), and the host-side oracle reads the same
config. The header is standard so the *envelope* is universally legible; the
payload is ours, exactly as a DBC is needed to read a CAN frame body.

On **rx**, the full envelope is validated against `[someip]` BEFORE anything
reaches the router: the UDP source must be the configured `peer`'s
address:port (static endpoints are a *filter*, not just a destination —
REQ-NET-017); the complete 32-bit Message ID (service high half, not just the
frame id), protocol and interface version, and a message type legal for the
phase must match; the Length must be consistent with the datagram; and the
payload length must EQUAL the destination's contract — the derived
signal-frame size, or the module endpoint's declared dlc (the CAN bridge's
`rx.len == dlc` rule; a self-consistent short datagram must never let a
fixed-layout decoder read stale buffer bytes). Any mismatch is counted and
dropped (REQ-NET-015) — a configured event id under a foreign service never
enters the shared routing/codec path.

## What this deliberately is NOT

- **No SOME/IP-SD on the target.** Endpoints, services, instances, and the
  subscriber are all fixed at build time from `[someip]`. Offer/find/subscribe
  over multicast is dynamic-topology machinery; a vehicle network fixed at
  config time doesn't have that problem. If third-party interop ever demands
  SD, it lands as a P4 rung — and even then, static-offer-only.
- **No ARXML/FIBEX import.** docs/architecture.md previously penciled SOME/IP
  config as "ARXML/FIBEX, not DBC"; this design supersedes that — the config
  is `ecu.toml`, same as everything else. An ARXML importer is host tooling
  (blobly_net territory) if a customer artifact ever forces it.
- **No segmentation (SOME/IP-TP), no dynamic-length types.** One event = one
  datagram, checked at build time. The trace/telemetry rings already batch into
  bounded records; nothing needs a 4 KB payload yet.
- **No client/subscriber management.** One configured peer. Multicast
  eventgroups (one send, N listeners) are the natural first relaxation and the
  header doesn't change — an open question below, not a P1 feature.

## Sim story (sim-first, as always)

`comm/someip` is ordinary tested V: header encode/decode + the tx/rx state,
unit-tested against golden byte vectors on the host, no sockets in sight —
the `comm/doip` split (tested V protocol over a four-call C byte-pipe seam,
`netx_glue.c`) is the proven pattern and applies unchanged. On the host build
the seam is a plain UDP socket on loopback, so the full path — cyclic event tx
from the comm thread, rx routing into modules — runs on the desk with
blobly_net (or `nc`/scapy/Wireshark) as the peer, the proven-on-vcan posture
carried to proven-on-lo. blobly_net's `modules/someip` (its deferred phase E3)
becomes the oracle: host encodes ↔ target decodes and vice versa, the same
two-repo pincer the CAN stack used.

## Phasing (bench rungs; H735-DK is the eth board)

1. **P1 — events tx (REQ-NET-013/017).** `comm/someip` header codec + the
   eth-bus tx path: a cyclic SIGNAL frame (the BenchTelem sketch) AND the
   trace module's record stream, both as NOTIFICATION events from the comm
   thread over the NetX UDP socket. The bench exercises ALL THREE configured
   tx modes REQ-NET-013 names — cyclic, on-change, mixed — not just the
   cyclic frame, or the requirement stays unverified. Bench: Wireshark's
   someip dissector decodes the stream from the H735; a scapy/blobly_net
   listener round-trips the payload against the config. This displaces the "dump trace over FDCAN"
   bandwidth ceiling ([[trace-as-com-module]]). REQ-NET-014 (the envelope) is
   *exercised* here but only *verified* at P3 — its text covers remote calls,
   which don't exist until then.
2. **P2 — events rx + routing (REQ-NET-015).** The rx direction: datagrams
   from the socket through the router into signals/module endpoints by frame
   id, same tables as CAN rx. Bench: drive a signal (the lamp, in the io
   tradition) from a host-sent event.
3. **P3 — request/response (REQ-NET-014/016/018).** REQUEST/RESPONSE/ERROR
   message types with request-id correlation; the shell (comm/shell) reachable
   as a SOME/IP method — the CAN shell's 0x7F0 family gets an eth sibling.
   Methods are MODULE-bound: a method id maps to a module's rx (request) and
   tx (response) endpoints, and the module owns both payloads — which is why
   one frame with one `signals` layout never has to describe two directions.
   A signal-layout method (per-direction derived layouts on one id) is out of
   scope until a concrete need exists. Three constraints the ComModule
   contract imposes, settled now rather than discovered in P3:
   - **One in-flight request per method.** The module contract carries frames,
     not correlation tokens, so the someip adapter holds the pending Request
     ID and answers an overlapping request for the same method with the
     standard busy/not-ready error — bounded state, no correlation table.
     (The DoIP server's one-connection-at-a-time posture, same reasoning.)
   - **Responses are one PDU.** `comm/shell` builds up to 520-byte responses
     and streams them over ISO-TP on CAN; there is no ISO-TP over the eth
     path and no segmentation. The eth shell adapter is therefore a bounded
     sibling, not a transparent port: responses that fit one PDU pass, longer
     ones are truncated with a marker — unless the wider-eth-PDU open
     question is resolved first, which P3 planning must decide explicitly.
   - **State-changing methods need a gate that exists.** REQ-NET-012 covers
     diagnostic services; `comm/shell` has no authenticated-session mechanism,
     so nothing is "inherited". REQ-NET-018 requires access control for
     state-changing remote calls: until an authentication gate is built, the
     eth shell exposes the read-only command subset only.
4. **P4 — SD, only if interop demands it.** Static offers + subscribe handling
   for a third-party consumer. Not scheduled; exists so the config surface
   above doesn't paint it out.

## Open questions (for when the phase starts)

- **Multicast events.** Unicast-to-one-peer is P1; a multicast group per
  eventgroup is the standard's answer to N listeners and NetX supports IGMP.
  Decide when a second listener actually exists.
- **PDUs wider than 64 bytes.** The datagram could carry ~1.4 KB, but the
  shared codec/router path is sized to `max_pdu = 64`; a wider payload means a
  separate statically bounded eth PDU type through that whole path. Decide
  when a real payload outgrows a CAN-FD frame — not before.
- **The `[someip]`/bus schema split.** `kind = "eth"` on the bus vs inferring
  from the `[someip]` binding — settle in ecumodel when the schema lands
  (reserved-name and validation details follow the io.md precedent).
- **H755 ETH bring-up.** The NUCLEO-H755ZI has the same MAC family + RMII PHY;
  the multicore node gets eth by porting `boards/h735dk/eth.c`, a separate
  bench rung when multi-node-over-eth is wanted (docs/multi-node.md).
- **NM on eth.** UDP-NM (`comm/nm_udp` over the same `comm/nm` state machine,
  docs/architecture.md) is orthogonal to SOME/IP and stays its own decision.

See docs/net.md (substrate + security posture), docs/com-modules.md (routing),
docs/multi-node.md (the system tier this feeds), [[eth-middleware-someip]].
