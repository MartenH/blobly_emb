# How do I move data from A to B?

Pick by **how far it crosses** and **how big it is**. The size limits below are hard —
most are build-time panics, not runtime truncation.

## The one principle

blobly separates **signal state** from **bulk**, and they are not interchangeable:

- **Signal state** is latest-value-wins: small, published continuously, and a reader only
  ever wants the newest complete value. Transports are wait-free and never block, so a
  slow reader costs the writer nothing. This is what `[[signal]]` generates.
- **Bulk** is a payload that must arrive *whole*: a log window, a firmware image, a
  measurement block. It needs an owner-held buffer, pacing, and an acknowledgement.

`boards/common/ioc.h` states the boundary outright: anything past the ceiling *"is not
signal state and rides an owner-buffer path (trace ring, ISO-TP link), never an IOC
cell."* Sending bulk as a signal is the mistake this page exists to prevent.

## The table

| crossing | transport | payload cap | generated? |
|---|---|---|---|
| same thread | plain struct field | — | ✅ derived |
| thread → thread, **same core** | IOC triple buffer (`ioc.h`) | **64 B** (`IOC_MAX`) | ✅ derived |
| **core → core**, same chip | xioc slot (`xioc.h`) | **8 B** — 1–2 × `u32` | ✅ derived |
| **core → core**, bulk | shared-memory owner buffer + handshake | RAM-bound | ❌ **hand-written** |
| ECU → ECU, one frame | CAN frame | 8 B classic / **64 B** FD | ✅ derived |
| ECU → ECU, a PDU | COM | **64 B** (`com.max_pdu`) | ✅ derived |
| ECU → ECU, bulk | ISO-TP | **520 B** (`isotp.max_payload`) | ✅ config |
| ECU → ECU, firmware | UDS `0x34`/`0x36`×N/`0x37` | image-sized, block-paced | ✅ bootloader |
| Ethernet event | SOME/IP notification | **64 B** | ✅ config |
| Ethernet RPC reply | SOME/IP response | **1024 B** (`max_rpc`) | ✅ config |

Transports are **derived, never configured** — you declare a `[[signal]]`'s endpoints and
the generator picks the mechanism from where they sit. See
[add-a-signal.md](add-a-signal.md).

## "I want to send object data between two cores"

**If it fits in two `u32`s, it is a signal.** Declare it normally:

```toml
[[signal]]
name   = "M4Sig"
fields = { n = "u32", acc = "u32" }   # 1..2 u32 fields ride one xioc {a,b} cell
from   = "m4"                          # a satellite partition
to     = "can0"
```

Anything else is rejected at generation, loudly and on purpose:

```
loom2v: remote signal "X" has 3 fields — the xioc cell carries 1..2 u32 fields
loom2v: remote signal "X" field "f" is u16 — the xioc cell carries u32 fields only
loom2v: remote signal "X" has a `valid` field — xioc freshness is the slot stamp
```

**If it does not fit, there is no generated path today.** You write the transfer yourself,
following the one worked example in the tree: the **cross-core trace handoff** in
[`boards/h755zi/duo.h`](../../boards/h755zi/duo.h). Its shape is the shape to copy:

- a **window in shared memory** both cores can reach — D3 SRAM4 (`0x38000000`, 64 KB),
  uncached on both by policy, so plain volatile accesses are coherent and no cache
  maintenance is needed;
- a small **control cell** — `{req_seq, op, ack_seq, count, …}` — with **one writer per
  field**, so no atomics and no locks;
- an **owner-buffer** after it (the trace path carries 256 records × 8 B = 2 KB);
- a **request/ack handshake**: the owner posts `req_seq++`, the satellite services it in
  its own loop and replies `ack_seq = req`. Neither side ever blocks on the other.

That is ~40 lines of C per side (`comm_glue.c` + `m4_glue.c`) and it is deliberately not
generated yet — see the roadmap item below.

**Why the 8-byte cap is not laziness:** `xioc` is wait-free on *both* sides using only
plain 32-bit stores and barriers, because the H755's cores do not arbitrate `LDREX`/`STREX`
between each other — the triple buffer that works within a core tore **162 reads in 200k**
across cores (measured 2026-07-12). A wider wait-free cell is a real design problem, not a
constant to bump.

### The planned shape: loan → fill → publish (what iceoryx solves)

The generated bulk path, when it lands, will use the **loan/publish** pattern (borrowed
from Eclipse iceoryx — the zero-copy transport behind AUTOSAR Adaptive's `ara::com`;
survey in [../bulk-transport.md](../bulk-transport.md)). It exists to kill two problems at
once, both of which any home-grown design here would otherwise hit:

- **The producer must not allocate** — but if it owns a static buffer instead, the
  transport has to *copy* out of it, and a concurrent reader can tear the copy. Every
  no-alloc bulk design collapses into this fork.
- **Copying bulk is the cost the path exists to avoid** — a 2 KB window copied
  producer→transport→consumer crosses the bus matrix three times.

The pattern dissolves both by inverting ownership — **the transport hands the producer a
buffer, never the reverse:**

```
producer:  loan()    -> a free buffer from the pool   (fails when the pool is empty)
           fill      -> write the payload IN PLACE — no staging copy
           publish() -> ownership moves via the descriptor ring; the producer
                        must not touch the buffer again
consumer:  take()    -> the oldest published buffer, by reference — still no copy
           release() -> the buffer returns to the pool
```

Zero copies end to end; no allocation anywhere (the pool is fixed at build time from
`ecu.toml`, so the RAM cost is visible in config); and back-pressure is **explicit and
designed** — when the consumer falls behind, `loan()` fails and the *producer* decides
drop-oldest / drop-newest / count-overflows, instead of a silent tear or an unbounded
queue. Loss stays detectable, never silent — the same discipline as everything else on
this page.

The consumer side is a **service thread** (see the Ethernet section below) — it sleeps on
the doorbell rather than polling. None of this is callable today; this section exists so
nobody designs a bulk producer around `memcpy` into a static buffer in the meantime.

## "I want to move object data to/from another ECU"

First, the structural point that decides everything else: **bulk is a module concern, not
an FB concern.** FBs read and write *signals* — COM-decoded, ≤64 B, latest-value-wins. A
multi-frame payload is owned by a **ComModule** (`uds`, `trace`, `shell`) that holds the
link and its buffer. There is no "raw bulk PDU → FB port" path, by design: an FB would
have to own a reassembly buffer and a timeout, which is exactly what the module does.

### On CAN — ISO-TP

Declare the connection:

```toml
[[isotp]]
name     = "diag"
bus      = "can0"
rx_id    = 0x101      # Request  (DBC)
tx_id    = 0x102      # Response (DBC)
bs       = 8          # flow-control block size we grant
stmin_ms = 0          # min separation we ask the sender for
```

The generator emits an `isotp.Link` plus a `[max_payload]u8` buffer into the ECU state and
wires the comm loop to it — you do not write the segmentation. The API either side of that
is two calls:

- **send** — `l.send(src, len)`; returns **`false`** if a transfer is already in flight or
  `len` exceeds the cap. *Check the return* — a dropped message is otherwise invisible.
- **receive** — `l.take(dst)` copies out one fully reassembled message and returns its
  length, or `0` if none is ready.

Where it terminates today: the shipped consumer is the **UDS server** (`0x22`/`0x2E` DIDs,
plus the bootloader's `0x34`/`0x36`×N/`0x37` block transfer). `comm/trace` owns its own
link the same way for the dump. A new bulk consumer follows that pattern — a module with
a link, not a new FB port.

**The cap is 520 B** (`isotp.max_payload`), sized to hold the largest thing the system
sends today (one trace dump block: 8 B header + 64 records × 8 B). Raising it grows *every*
link's buffer, so it is a deliberate ceiling. For anything image-sized use the bootloader's
block transfer instead — it acks per block and lets ISO-TP flow control pace it.

**Two failure modes, and they are asymmetric:**

- **Sending too much fails loudly-ish** — `send()` returns `false` and transmits nothing.
- **Being *asked* to receive too much fails silently.** A FirstFrame declaring more than
  `max_payload` is ignored: no reassembly starts and **no OVFLW flow-control is sent**, so
  the peer just sees silence and times out. (We *honour* an OVFLW we receive, but never
  emit one.) If a remote transfer mysteriously stalls, check its declared length first.

### On Ethernet — SOME/IP over UDP

**An FB never opens a socket.** `make lint` (a CI gate) rejects `import driver` anywhere
except `main.v` and the generated bridge, so there is no `udp_send()` to call from
application code. That is the same rule as everywhere else here: the app reads and writes
signals; *which wire they leave on is configuration.*

So "send this over Ethernet" is a one-word change — the bus a signal points at:

```toml
[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"

[someip]
bus     = "eth0"
service = 0x0100
version = 1
port    = 30490

[[signal]]
name   = "BenchLoad"
fields = { load = "u8" }
from   = "app"
to     = "eth0"       # <- CAN would be "can0"; nothing else differs
```

That signal becomes a **SOME/IP notification** in a UDP datagram: the standard 16-byte
header plus the build-time payload layout, legible to Wireshark and to blobly_net's
`someip` module. Bench-verified on the H735 (NetX).

**The limits, and they are tight:**

| | limit |
|---|---|
| event payload (tx and rx) | **64 B** (`com.max_pdu`) |
| rx datagram buffer | `[80]u8` = 16 B header + 64 B — **an oversize datagram truncates and is dropped by the Length gate** |
| method response | **1024 B** (`max_rpc`) — the one payload allowed past the PDU bound |
| addressing | one static peer ip/port; a datagram from anywhere else is discarded |

### TCP/UDP from an application — the service-thread pattern

Blocking socket work has a home, and it is not an FB (which must finish inside its period
and may never block): it is a **service thread** — an ordinary ThreadX thread paced by the
*data* instead of the clock. NetX is ThreadX-native, so
`nx_tcp_socket_receive(&sock, &packet, timeout_ticks)` blocks that thread properly, with a
timeout — no polling, no callbacks.

The worked example to copy is [`examples/h735_doip`](../../examples/h735_doip):

- `netx_glue.c` owns ThreadX/NetX/the sockets and exposes a **four-call seam**
  (`net_stream_recv/send`, timeout in ticks, plus a drop and a notify);
- a dedicated thread runs the **V protocol loop** against that seam — blocking recv with a
  bounded timeout, every byte above the stream unit-tested V (`comm.doip` + `comm.uds`).

The seam is the point: the thread never calls NetX directly, so the loop stays pure V and
testable on the host, and the isolation rule holds (the glue is the driver boundary, like
`main.v`).

**Which NetX API:** the **native `nx_*` services** (`nx_tcp_socket_*`, `nx_udp_socket_*`),
which is what every shipped example uses. The vendored tree also carries a **BSD
socket-compat addon** (`third_party/netxduo/addons/BSD`) — don't reach for it: it layers
its own internal locking and select emulation over the native calls to fake POSIX, buys
nothing here (the native calls already block-with-timeout from a thread), and widens the
no-alloc surface for free. One native-API trap is already documented and will bite a
re-accept loop: server sockets accept with `NX_WAIT_FOREVER` and bound only the receive —
see [../net.md](../net.md) ("`nx_tcp_server_socket_accept` … is a NetX trap").

Today you copy that glue by hand; making the service thread + seam **declarable**
(a `[[partition.thread]]` with an endpoint binding, glue generated) is on the roadmap.

**What does not exist today** — worth knowing before you design around it:

- **No app-facing socket API.** No UDP stream, no TCP connect, no app-initiated
  request/response from an FB. TCP on the target is used by **DoIP** (UDS over TCP, for
  diagnostics and OTA) — a module, not an application path.
- **No streaming.** The eth signal path is latest-value-wins, like every other signal
  path. Continuous or unbounded data has no first-class route; today that means platform
  glue owning the socket in `main.v`, the same shape as bulk on CAN.
- **No service discovery** — SOME/IP is adopted as a *wire format*, not a middleware. The
  peer is configured, not discovered.

If you need one of those now, it is platform work (a module owning the socket), not
something you can reach from an FB. The roadmap tracks making the ordinary cases —
UDP/TCP/RPC from an application — first-class rather than special.

See [../someip.md](../someip.md) and [../net.md](../net.md).

### Which ECU it even goes to

Nothing above says *which* node. That is the system layer: declare the nodes and buses in
`system.toml` and the generator wires each node's half and any gateway route. Start with
[two-node-io.md](two-node-io.md) (a signal across two real ECUs, end to end), then
[system-from-nodes.md](system-from-nodes.md) for how `system.toml` and `ecu.toml` merge.
If the two ECUs are on *different* buses, the traffic crosses a gateway —
[gateway-a-frame.md](gateway-a-frame.md).

## Pacing bulk without starving the bus

The trace dump is the reference for streaming a large window out of a running ECU without
a `malloc` or a stall: `pack_chunk()` emits **one ISO-TP payload at a time**, each block
self-describing, and the owner interleaves rx-drain between chunks so back-pressure and
liveness stay with the bus owner. Copy that shape for any new bulk producer — freeze,
snapshot, then stream in bounded chunks.

## See also

- [add-a-signal.md](add-a-signal.md) — declaring endpoints; how transports are derived
- [../multi-image.md](../multi-image.md) — cross-core signals and the xioc slot model
- [../multicore-perf.md](../multicore-perf.md) — IOC transports, measured costs, `ioc_bench`
- [../communication.md](../communication.md) — COM, router, ISO-TP, UDS
- [gateway-a-frame.md](gateway-a-frame.md) — moving traffic between buses
- [two-node-io.md](two-node-io.md) · [system-from-nodes.md](system-from-nodes.md) ·
  [../multi-node.md](../multi-node.md) — getting data to a *different ECU* at all
- [../com-modules.md](../com-modules.md) — why bulk is owned by a module, not an FB
- [../bulk-transport.md](../bulk-transport.md) — the bulk design survey: how ROS 2/iceoryx/
  RPMsg/Linux solve this, the portable contract, and the service-thread model
