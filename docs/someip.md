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
declarations, same build-time codec, same frame→module routing
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

# The service identity + static endpoints. One [someip] block per eth bus for
# now (multi-service is a later generalisation if a real need appears).
# peer — where events/responses go and where requests come from. STATIC: no SD.
[someip]
bus      = "eth0"
service  = 0x0100
instance = 0x0001
port     = 30490
peer     = "192.168.0.10:30490"

# Frames on an eth bus reuse the id field as the SOME/IP method/event id
# (bit 15 set = event/notification, per the standard). Signals ride frames
# exactly as on CAN; the payload bytes ARE the frame codec's packing.
[[frame]]
name = "BenchTelem"
bus  = "eth0"
id   = 0x8001
tx   = { mode = "cyclic", cycle_ms = 100 }
```

What ecucheck adds (same rule family as the io bindings, docs/io.md):

- an eth-bus frame id must fit 16 bits and its direction must match the id
  class — tx event frames set bit 15, rx method (request) frames clear it;
- an event frame's packed payload must fit ONE datagram (pool payload minus
  IP/UDP/SOME-IP overhead) — segmentation (SOME/IP-TP) is out of scope, so an
  oversize frame is a config error, not a runtime surprise;
- `[someip]` requires an existing `kind = "eth"` bus; a `[someip]` block
  without eth frames, or eth frames without a `[someip]` block, is an error —
  half-configured transports fail loud at build time.

## The wire subset

The 16-byte header, big-endian on the wire as the standard requires:

| Field | Size | blobly binding |
|---|---|---|
| Message ID | 32 | `service` (high 16) + frame `id` (low 16) |
| Length | 32 | 8 + payload length (bytes after this field) |
| Request ID | 32 | events: client 0x0000 + a per-frame session counter (wraps 1..0xFFFF — receivers get loss detection for free); requests: echoed into the response |
| Protocol version | 8 | 0x01 |
| Interface version | 8 | derived from the config (a truncated hash of the eth frame table) — a mismatched build fails loud at the header, not as garbled signals |
| Message type | 8 | P1: NOTIFICATION (0x02). P3 adds REQUEST (0x00) / RESPONSE (0x80) / ERROR (0x81) |
| Return code | 8 | 0x00; P3 error paths use the standard codes |

The **payload** is the frame codec's packed bytes — the same packing the CAN
path uses, little-endian scalars as the DBC/codegen already define. That is a
declared deviation from AUTOSAR's default big-endian payload serialization:
SOME/IP the wire standard does not mandate payload endianness (it is
deployment-defined), the codec already exists and is tested, and the host-side
oracle knows the layout from the same config. The header is standard so the
*envelope* is universally legible; the payload is ours, exactly as a DBC is
needed to read a CAN frame body.

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

1. **P1 — events tx (REQ-NET-013/014/017).** `comm/someip` header codec +
   the eth-bus tx path: cyclic telemetry/trace egress as NOTIFICATION events
   from the comm thread over the NetX UDP socket. Bench: Wireshark's someip
   dissector decodes the stream from the H735; a scapy/blobly_net listener
   round-trips the payload against the config. This displaces the "dump trace
   over FDCAN" bandwidth ceiling ([[trace-as-com-module]]).
2. **P2 — events rx + routing (REQ-NET-015).** The rx direction: datagrams
   from the socket through the router into signals/module endpoints by frame
   id, same tables as CAN rx. Bench: drive a signal (the lamp, in the io
   tradition) from a host-sent event.
3. **P3 — request/response (REQ-NET-016).** REQUEST/RESPONSE/ERROR message
   types with request-id correlation; the shell (comm/shell) reachable as a
   SOME/IP method — the CAN shell's 0x7F0 family gets an eth sibling. State-
   changing methods inherit the net security posture (docs/net.md, REQ-NET-012).
4. **P4 — SD, only if interop demands it.** Static offers + subscribe handling
   for a third-party consumer. Not scheduled; exists so the config surface
   above doesn't paint it out.

## Open questions (for when the phase starts)

- **Multicast events.** Unicast-to-one-peer is P1; a multicast group per
  eventgroup is the standard's answer to N listeners and NetX supports IGMP.
  Decide when a second listener actually exists.
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
