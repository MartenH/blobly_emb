# On-target networking — TCP/IP over Ethernet

> Design sketch (2026-07-17). The H735-DK is now wired to Ethernet on the bench;
> this brings a **TCP/IP stack on the target**. The thesis mirrors the crypto
> decision (docs/no-alloc.md "the maintenance line"): a full TCP/IP stack is
> evolving and security-adjacent — we **pull a vetted implementation and give it
> a bounded pool**, we do not hand-roll a no-alloc fork. The chosen stack is
> **NetX Duo**, the natural pair for the ThreadX kernel we already run.

## Why NetX Duo (not lwIP, not from scratch)

| Option | Verdict |
|---|---|
| **NetX Duo** (Eclipse ThreadX) | **Chosen.** Native ThreadX integration — its own threads, semaphores and timers are ThreadX primitives, so it drops onto the H735 kernel with no shim. Packet **pools** (no heap). Same vendor/license as the ThreadX we already vendored (third_party/threadx). IPv4+IPv6, UDP, TCP, and the app protocols (DNS, DHCP, mDNS…) come in the box. |
| lwIP | Also pool-based (`pbuf`/`MEMP`) and RTOS-agnostic, but needs a `sys_arch` port shim to ThreadX and its own thread/mailbox model layered on ours — more glue, second scheduler-ish surface. lwIP is the *generic* reference no-alloc.md cites; NetX Duo is the ThreadX-native realization. |
| Hand-rolled | Rejected by the maintenance-line rule: TCP retransmit/congestion/reassembly is a large, security-sensitive surface to carry no-alloc forever. Not our value. |

## Memory model — tier-1 packet pools (docs/no-alloc.md)

NetX Duo never calls `malloc`. It allocates from **packet pools** created over a
**static** buffer: `nx_packet_pool_create(&pool, "rx", PAYLOAD, &g_pool_mem[0],
sizeof(g_pool_mem))`. That is exactly a **tier-1 bounded pool** — fixed block
size, fixed count, provable ceiling, "pool empty" is a handleable return (drop
the packet), not an OOM. The IP instance, TCP/UDP sockets, ARP cache and the
driver's DMA buffers are likewise sized at config from static memory.

Sizing is the safety claim: `RX_PACKETS + TX_PACKETS` blocks of `MTU`-sized
payload, plus the ETH DMA descriptor rings, are all `static` arrays. Worst-case
footprint is fixed at build time — what an MPU layout and a safety case need. No
`-gc none` surprise, no fragmentation stall mid-transfer.

**What this does NOT relax:** `app/ comm/ loom/` stay strict-static (tier 0). The
pools live with the net subsystem (like `osal/`/`driver/` init), reviewed as the
sanctioned exception — `make lint` treats the net module the way it treats a
tier-1 pool owner.

## The Ethernet driver (the bulk of the target work)

The STM32H7 has an **ETH MAC + dedicated DMA**; the H735-DK carries a **LAN8742A**
PHY on **RMII** to an RJ45. NetX Duo needs one thing from us: a **network driver**
(`nx_driver`) exposing the standard entry (`_nx_driver_*`) that:

1. **Init** — clock the ETH (RCC), mux the RMII pins (REF_CLK, MDIO/MDC, TXD/RXD,
   CRS_DV, TX_EN), bring up the PHY (soft-reset, auto-negotiation), configure the
   MAC (address, checksum offload) and the DMA descriptor rings.
2. **RX** — the ETH DMA fills receive descriptors; the ETH ISR posts to the
   driver, which wraps each filled DMA buffer as an `NX_PACKET` and hands it up
   (`_nx_ip_packet_receive`). Zero-copy where the H7 cache policy allows (D-cache
   is off by policy on our boards — see [[icache-flash-fetch-lottery]] — which
   *simplifies* coherency: no descriptor/buffer clean+invalidate dance).
3. **TX** — take an `NX_PACKET` chain, point a TX descriptor at it, kick the DMA,
   release the packet on the TX-complete interrupt.
4. **Link** — poll/interrupt the PHY for link up/down + speed/duplex, tell NetX
   (`NX_LINK_ENABLE`), and gate the MAC speed to the negotiated rate.

This is a `boards/h735dk/eth.c` (register-level, like `board.c`/`flash.c`) plus a
thin `nx_driver_stm32h7.c`. It is the one genuinely new hardware bring-up; the
stack above it is vendored.

## How it fits blobly

- **Its own thread(s).** NetX Duo runs an internal IP thread; our driver adds an
  ISR + a deferred-work path. These are ordinary ThreadX threads/priorities in
  the manifest (like the comm thread, [[platform-scheduling-comm-thread]]) — the
  net stack is a first-class partition, not a bolt-on.
- **Diagnostics/OTA over IP = DoIP.** The headline use case: **UDS over TCP/IP**
  (ISO 13400, "DoIP"). We already have the UDS server (`comm/uds`) and the boot
  programming session; DoIP is a *different transport* under the same UDS logic —
  swap the ISO-TP link for a TCP socket. That gives Ethernet reflash + diagnostics
  for the multi-node **diag bus** tier (docs/multi-node.md): the Linux/cloud node
  attaches over Ethernet instead of CAN, and the H735 sysnode is the DoIP edge/
  gateway (it already stages OTA images in its storage).
- **Telemetry.** The trace/telemetry dump ([[trace-as-com-module]]) can egress
  over UDP to the observer, off the CAN bus — higher bandwidth for the flight
  recorder.
- **Codegen fit.** Long-term, an Ethernet endpoint is another rung on the
  transport ladder (docs/multi-node.md): a signal `to = "eth"` or a DoIP diag
  address in `system.toml`, wired by the generator. Not P1 — the stack first.

## Phasing (bench rungs on the H735-DK)

1. **P1 — link + ping.** ETH MAC/DMA/PHY bring-up, the `nx_driver`, one packet
   pool, IP instance, ARP + ICMP. Bench: `ping` the H735 from the WSL host over a
   direct cable. Proves the driver + pool + link management end to end.
2. **P2 — UDP.** A UDP socket: echo, then a telemetry sender (the CpuLoad/trace
   ring over UDP to a host listener). Proves TX + the app-facing socket API.
3. **P3 — TCP + DoIP.** A TCP echo, then **DoIP**: the UDS server over a TCP
   socket (reuse `comm/uds` + the boot `Prog`), announced/discovered per ISO
   13400. Bench: run a UDS session (0x22/0x3E, then the programming services)
   over Ethernet.
4. **P4 — OTA over IP.** Reflash a node over DoIP end to end — the Ethernet path
   for the bootloader ([[bootloader-phase]]), and the multi-node diag tier
   (docs/multi-node.md P3/P4) attaching over Ethernet rather than CAN.

## Security posture

DoIP is a remote attack surface in a way ISO-TP-over-CAN is not (routable, often
internet-adjacent via the master node). The boot's asymmetric authenticity
defends the *image* (Ed25519 signed, 0x29 gated — [[bootloader-phase]]) — but
that protection is **conditional on a provisioned key**, and normal diagnostics
are **not** gated by it. Two things must therefore be closed BEFORE the
programming/diag path is exposed over IP, not after:

- **A trust anchor is mandatory on an IP build (REQ-NET-011).** `boot.Prog` treats
  an all-zero `image_key` as a keyless/open build and *skips* signature
  verification (`test_keyless_build_flashes_open` covers that mode) — fine for a
  closed bench, catastrophic if reachable over a routed network. An IP-enabled
  build must refuse to boot the programming path with an unset image key.
- **State-changing diagnostics need authentication (REQ-NET-012).** Over CAN an
  unauthenticated 0x2E or 0x11 is a physically-present adversary; over IP, reachability
  alone would grant it. Closed for DoIP (the sysnode section below): a `[doip]` node's
  every state-changing service carries a 0x27 level, and the unlock that level asks for
  is the network tester's own. A routing-activation tester list (`[doip] testers`, below)
  does not close this: it filters claimed source addresses, which are not authenticated.

Beyond those, P3+ must consider: rate-limiting/SYN-flood resistance (bounded
pools already cap resource exhaustion to "drop", not crash) and — later — **TLS**
for the diag channel (again vendored, given a pool; never hand-rolled).
Confidentiality of diagnostics is out of scope for P1–P4; image authenticity is
in **once the trust anchor is provisioned and the keyless bypass is closed on IP
builds** (REQ-NET-010/011).

## Open questions (for when the phase starts)

- **NetX Duo vendoring.** Same treatment as ThreadX (third_party/, pinned) — a
  `make deps` rung. Confirm the license file travels and the build picks only the
  modules we use (IPv4/UDP/TCP/ICMP first; DNS/DHCP/TLS later).
- **PHY address / RMII pinout.** Read from the H735-DK schematic (LAN8742A
  address, the exact RMII GPIO map) — the one board-specific unknown.
- **Static IP vs DHCP for the bench.** P1 static (direct cable, link-local); DHCP
  is a later NetX module. Keep bring-up cable-direct, no switch.
- **DoIP vs a simpler custom UDS-over-TCP.** DoIP (ISO 13400) is the standard and
  interoperates with real testers; a bespoke framing is less work but non-
  standard. Recommended: DoIP, since the tester (blobly_net) can speak it and it
  matches the "real 0x29/real bus matrix" posture the rest of the stack takes.

See [[functional-scope]] (Ethernet = NetX Duo), [[bootloader-phase]] (DoIP OTA
path), docs/multi-node.md (the diag bus tier), docs/no-alloc.md (tier-1 pools).

## P1 implementation status (2026-07-17)

**Vendored + build-wired.** NetX Duo is cloned + pinned under `third_party/netxduo`
via `make deps` (`NETXXCORE_PIN`, alongside ThreadX). Its Cortex-M7/GNU port
(`ports/cortex_m7/gnu`) matches the H735, and `common/inc/nx_api.h` is the stack
API. The structural reference for our driver is NetX's own RAM driver
(`test/regression/test/nx_ram_network_driver_test_1500.c`) — it shows the exact
`_nx_driver_*` command dispatch we mirror.

**P1 = link + ping** (REQ-NET-003/004): a packet pool + IP instance + ICMP, over
the STM32H7 ETH MAC/DMA + LAN8742A RMII driver. The stack above is vendored; the
driver (`boards/h735dk/eth.c` register-level + `net/nx_driver_stm32h7.c` NetX glue)
is the one new hardware bring-up.

### RMII pinout (confirmed)

RMII pinout — CONFIRMED from the stm32h7xx-hal H735G-DK ethernet example (working
reference code, cross-checks the ST BSP) + the user (PHY address = 0). All ETH
signals are alternate function AF11:

| RMII signal | STM32H735 pin (AF11) |
| --- | --- |
| REF_CLK  | PA1 |
| MDIO     | PA2 |
| MDC      | PC1 |
| CRS_DV   | PA7 |
| RXD0     | PC4 |
| RXD1     | PC5 |
| TX_EN    | PB11 |
| TXD0     | PB12 |
| TXD1     | PB13 |
| LAN8742A MDIO/SMI address | **0** |
| PHY nRST | none dedicated (soft-reset over MDIO; board NRST/power-on) |

### P1 BENCH-VERIFIED (2026-07-18)

The full P1 stack is **verified on the H735-DK**: link + ARP + IPv4 + ICMP, both
directions, 0% ping loss at ~1 ms RTT (`ping 192.168.0.50` from the host; the
board pings its gateway). Built then as `examples/h735_net`, a hand-wired image retired in #340:
the same driver now comes up from config on every networked node (`driver/eth/netx_up.c`,
`gen/loom_build.mk`'s `LOOM_NET_SRCS`) — sysnode and tcu answer ping on the bench.

- **`boards/h735dk/eth.c` + `eth.h`** — register-level ETH MAC/DMA (RM0468): RCC +
  RMII pin mux (the AF11 table above), `SYSCFG_PMCR` RMII select, LAN8742 soft-reset
  + auto-neg over MDIO, 4+4 descriptor rings, `eth_send`/`eth_recv`, `ETH_IRQHandler`.
- **`net/nx_driver_stm32h7.c`** — the NetX `NX_IP_DRIVER` command dispatch (mirrors
  the vendored RAM driver): TX linearises the packet chain → `eth_send`; the RX ISR
  signals `_nx_ip_driver_deferred_processing`, and `DEFERRED_PROCESSING` drains
  `eth_recv` into `NX_PACKET`s routed by EtherType. Copy-based, so only eth.c's
  buffers touch DMA.
- **`examples/h735_net/`** (retired in #340) — was a plain-C ThreadX+NetX app (no loom2v/CAN):
  packet pool + IP + ICMP, bringing the link up and pinging the gateway on a loop, with the
  outcome in `net_ping_ok` / `net_ping_fail` / `net_link_up` globals read over SWD.

Two hardware facts drove the layout: **D-cache is off** (docs/no-alloc.md), so DMA
needs no clean/invalidate; and the ETH DMA is an AHB master that **cannot reach the
DTCM** the rest of RAM sits in, so the descriptor rings + frame buffers live in a
`.eth_dma` section in **D2 AHB SRAM (0x30000000)** — a new region in `threadx.ld`,
its clock enabled in `eth_init`. The shared `boards/common/vectors.S` is extended to
IRQ61 (ETH); non-net images resolve it via a **weak** `ETH_IRQHandler` in each
board's `board.c` (separate object, so no `--gc-sections` capture).

### P1 bring-up findings (all silicon-found, all fixed)

The register bring-up (clocks, RMII mux, PHY, rings) worked first flash; every bug
was in the seams between the driver, NetX, and the M7 memory model:

1. **Link-up latch** — NetX issues `NX_LINK_ENABLE` before PHY auto-negotiation
   (~2-3 s) completes; gating `nx_interface_link_up` on the instantaneous PHY status
   latched "down" and NetX never transmitted a single frame. Report up at ENABLE.
2. **TX checksum offload vs NetX** — `TDES3 CIC=3` made the MAC overwrite NetX's
   software-computed checksums (wrong for ICMP): every IP frame dropped by the peer,
   while ARP (no checksum) sailed through. Offload off; NetX owns checksums.
3. **IP-header 4-byte alignment (the "50% loss")** — NetX's checksum routine reads
   32-bit words; an IP header at frame+14 with the frame 4-byte aligned lands 2 mod 4
   and mis-sums ~half the packets (pool-position dependent) → dropped as checksum
   errors. RX path now offsets each frame so the IP header is 4-byte aligned.
4. **DSB before the DMA doorbell (the "one frame behind")** — the M7 store buffer
   can deliver the device-memory tail-pointer write before the normal-memory
   descriptor OWN write; the DMA fetches OWN=0 and idles, transmitting the frame only
   on the NEXT doorbell (frames left the board in back-to-back pairs). `__DSB()`
   between descriptor stores and `DMACTDTPR`/`DMACRDTPR`.

Also tuned on-bench: `NX_IP_PERIODIC_RATE`/`TX_TIMER_TICKS_PER_SECOND` forced to
1000 to match the 1 kHz SysTick (nx_port.h hard-defines 100 → every NetX timeout ran
10x fast), speed/duplex read from the PHY's negotiated result instead of hardcoded,
and RX ring sized 16 (4 could overflow on a broadcast-heavy LAN).

Bench diagnostics that survived into the code: `eth_rx/tx/isr_count` +
`eth_phy_pscsr` (eth.c) — and, in the retired h735_net app, `net_ping_ok/fail`, `net_link_up` — read over
SWD with openocd (`init; halt; mdw <addr>; resume`). NOTE: st-util resets the target
on attach and silently wipes this state; use openocd for live reads.

~~P2 debt — drop the autoneg wait from eth_init.~~ **Retired with P2**: the app's
1 Hz GET_STATUS poll owns speed/duplex (per-poll MACCR sync), so eth_init now
configures and returns — nothing blocks the IP thread.

## P2 status — UDP datagram service (2026-07-18, BENCH-VERIFIED)

REQ-NET-005 on silicon, in `examples/h735_net` (retired in #340; the datagram service is now
exercised by every generated SOME/IP node — `examples/system_full/nodes/tcu/bench_test.sh`
probes the tcu): a UDP **echo** socket (port 5005,
every datagram straight back to its sender — verified round-tripping from a WSL
host through the Windows NAT) and a 1 Hz **telemetry broadcast** (port 5006, the
bench counters as a text line to the subnet — the CpuLoad-over-CAN idea carried to
UDP; `nc -ul 5006` on any subnet host). Notes: NetX's bind path calls `rand()`
for ephemeral ports — newlib-nano's rand drags the reent/malloc/_sbrk chain, so
the image provides a local xorshift32 (no-alloc preserved).

## P3a status — TCP echo (2026-07-18, BENCH-VERIFIED)

REQ-NET-006's byte-stream service on silicon (on the retired `examples/h735_net`; the stream
service is now exercised by DoIP on sysnode, below): a single-connection TCP echo
server (port 5007, 2 KB window, re-listens after each disconnect) — verified
with three full connect/echo/disconnect cycles from a WSL host
(`echo hi | nc -w2 192.168.0.50 5007`). +13 KB flash for the NetX TCP engine.
P3b followed — DoIP (REQ-NET-007), the UDS server over a TCP socket, announced per
ISO 13400: on its own image first (below), then generated onto a running node (sysnode, below).

## sysnode — DoIP on a running node (2026-10-02, BENCH-VERIFIED)

`[doip]` in a ThreadX node's ecu.toml (`address`, `logical_address`, optional
`functional_address` and the transport policy below) puts the node's ONE diagnostic server on TCP/UDP 13400 too:
`driver/eth/doip_netx.c` runs two threads on the image's ONE NetX (doip: the TCP loop the
generator emits; doip-svc: link poll + the UDP requests — identification, entity status,
power mode), and hands each
request to the CAN comm thread through a mailbox — the server keeps one owner
thread. The VIN announced is DID 0xF190. Generation refuses a state-changing service
reachable without a security level and the public bench key unless named (REQ-NET-012, below —
sysnode names it: `allow_bench_key = true`, a bench posture), an entity address outside ISO 13400's
entity ranges, and an eth bus at another address (a node has one). TCP initial
sequence numbers come from the TRNG (the comm thread draws the seed). Bench:
`examples/system_full/test/doip_sysnode.lua` on the H735 — discovery, sessions,
DIDs, 0x27 + the gated 0x2E, one server and one session across DoIP and CAN with
each transport's unlock its own, and ECUReset
answered over TCP before the restart. With ECUReset gated (REQ-NET-012) it also refuses
0x11 without DoIP's own unlock and resets under it — 6/6 on the bench 2026-10-02; the DoIP
wrong-key leg added after that run is not yet rerun.

**Declared by the system, not the node** (rung 6): sysnode's address and DoIP entity
address are `endpoint = { address = "192.168.0.50", port = 30490 }` and
`doip = { logical = 0x07A0 }` on its `[[node]]` in `examples/system_full/system.toml`;
sysgen lowers them into its `[doip]` and — because sysnode is now a member of the `tel`
SOME/IP segment beside tcu — its `[bus.eth0]`/`[someip]` too. It publishes one event
there, `GwStatus` (0x8020, `GwUptime { seconds u32 }`, cyclic 1 s, from the GwHealth FB),
to the bench tool's endpoint (192.168.0.190:30491, the same one tcu sends to), and its
CAN routes are unchanged: nothing routes between CAN and SOME/IP. So the image runs the
comm thread (routes, NM, the diagnostic server), the eth thread (SOME/IP) and the doip
threads on one NetX, and its node `ecu.toml` authors none of its network. The tel segment
now has three members, so each EVENT is the point-to-point unit (docs/multi-node.md) and
the bench tool's generated config names `GwStatus`'s producer as that event's own `peer`.

### The entity at the transport level (ISO 13400-2:2012)

What the entity does with each payload type, and the policy that is configuration rather than
code. The bounds and defaults live once in `comm/doip/policy.v`, and one build-time reader,
checker and writer (`tools/doipcfg`) serves loom2v (`[doip]`), syscheck (a node's
`doip = {...}`) and sysgen (which lowers the one into the other under the same names).

| key (`[doip]` and a node's `doip`) | default | meaning |
|---|---|---|
| `testers` | absent: any 0x0E00..0x0FFF | tester logical addresses allowed to activate routing (1..8, each in the tester range; an empty list is refused, it would read as "any") |
| `activation_types` | `[0x00]` | routing activation types served (≤ 4; 0x00, 0x01, 0xE1..0xFF — 0xE0 central security is refused, nothing here authenticates) |
| `initial_inactivity_ms` | 2000 | T_TCP_Initial_Inactivity, from accept (100..60000, ≤ the general one) |
| `general_inactivity_ms` | 300000 | T_TCP_General_Inactivity, idle after activation (1000..3600000) |
| `announce_count` | 3 | A_DoIP_Announce_Num, boot announcements (0..10; 0 = discovery by request only) |
| `announce_interval_ms` | 500 | A_DoIP_Announce_Interval between them (10..10000; count × interval ≤ 10 s, since the doip thread accepts no tester while it announces) |

| payload type | TCP | UDP 13400 |
|---|---|---|
| 0x0005 routing activation | checked in the spec's order: source address (**0x00** unknown source — outside the list, or outside 0x0E00..0x0FFF with no list), activation type (**0x06** unsupported), the socket (**0x02** a different source address on this already-registered socket); else **0x10**, and the registered address may activate again. Every refusal closes the socket after the response, and nothing queued behind it is served | silence |
| 0x0007 alive check request | answered 0x0008 with the entity's address (the spec sends this request the other way; answered as a liveness probe) | silence |
| 0x0008 alive check response | accepted, no reply (2-byte payload) | silence |
| 0x4001 entity status | 0x4002: node type 0x01 (node), max sockets 1, open sockets 1, max data size 248 | 0x4002, open sockets 0 or 1 |
| 0x4003 diagnostic power mode | 0x4004: 0x01 ready | 0x4004 |
| 0x0001..0x0003 identification | NACK 0x01 | the announcement (0xFF/0x00 version pattern accepted for these only) |
| 0x8001 diagnostic message | as before (acks 0x8002/0x8003) | silence |
| anything else | generic NACK 0x01 | silence |
| a payload length its type does not allow | generic NACK 0x04, and the socket closes | silence |

Max data size is the assembly buffer's payload room (256 − 8): a message sized to it fits whether a
tester reads the field as the payload or the whole message. A malformed UDP request gets silence,
never a NACK, as identification always has.

**One TCP_DATA socket** (`max_sockets`, NetX listen backlog 1). So the socket handler's other
outcomes do not arise: a second tester's SYN waits in NetX's listen queue, unanswered, until the
first connection closes or idles out — it never receives **0x01** (all sockets in use) or
**0x03** (source address active on another socket), and the entity never runs the alive check
(0x0007 to the registered tester, T_TCP_Alive_Check 500 ms) that decides between them. That needs
a second NetX socket to accept the contender on, and a listen-queue signal NetX does not give
(its listen callback fires only when a socket is free), so it is left. Also not built: the
random A_DoIP_Announce_Wait before the first announcement, and routing activation's
authentication / confirmation steps (codes 0x04, 0x05, 0x11).

**REQ-NET-012: an authenticated session in front of every state-changing service.**
`testers` is a policy, not authentication: a source address is whatever the tester writes into
its request, so the list keeps honest testers on their own addresses and nothing more. What
closes the requirement is two rules that already existed, joined by one at generation:

- **The unlock belongs to the transport that earned it** (`comm/diag` enter/leave): a request
  over DoIP sees the server locked unless a 0x27 exchange over DoIP unlocked it, whatever the CAN
  tester holds, and the reverse. The cross-transport model in `comm/diag/diag_test.v` checks it
  over random interleavings, once on the default table and once with 0x11 gated.
- **Every service a `[doip]` node performs that changes ECU state carries a security level**
  (`tools/doipcfg` `service_refusals`, applied by loom2v's `validate_doip` and by syscheck's
  `check_doip` alike): a writable DID needs `write = { security = N }` or a security level on
  the `[uds] services` `"0x2E"` row (comm/uds checks the row before the DID, so a gated row gates
  every write behind it), and every other service needs a row with `security = N` — or is left
  out of the table. The rule lists what is EXEMPT (`open_services`), not what is gated: 0x10 and
  0x3E (reaching and keeping a session), 0x27 (authenticating, which no 0x27 gate can itself
  require), 0x22 and 0x19 (reads), and 0x2E (gated as above). Everything else — 0x11 ECUReset,
  0x14 clearing the fault memory, 0x85 freezing it, 0x28 silencing the bus — must be gated. It is
  fail-closed: the default table (no `services`) serves whatever the build performs with no
  security, so a `[doip]` node with no table is refused outright, and a service comm/uds learns
  later is reachable there only through a row, which this rule judges.
- **The key the level is checked with is not one anybody can compute.** `[uds] security_key =
  "reference"` is blobly_net's PUBLIC reference key; over a routed network it authenticates
  nobody, so a `[doip]` node may use it only by name: `allow_bench_key = true` in `[doip]` (on a
  system's `[[node]]`, in its `doip` table; refused when it names no bench key). sysnode sets it —
  the closed bench. **What is verified is the mechanism** (a state change over IP needs that
  tester's own unlock, `comm/diag/diag_test.v` and the generator's refusals,
  `tools/loom2v/doip_target_test.v`); a production key is the OEM's: `diag_sa_key_ok`, which the
  node's glue supplies (none is linked by default — `boards/common/diag_board.c`), and which a
  node with no `security_key` must link.

So over IP a state change answers securityAccessDenied (0x33) until THAT tester has unlocked, in
ISO 14229-1's order (a service outside its session still answers 0x7F first). The gate is one
row, shared with the bus: a `[doip]` node's CAN tester needs its own unlock for the same service
too — the requirement asks for the network "not only" the bus, and a second, network-only table
would be a second copy of the per-service gate inside `comm/uds`.

**What an unauthenticated network tester can still do** is deny diagnostics, not change ECU
state. 0x10 is open: it can move the SHARED session, which relocks the bus tester's unlock (every
session entry relocks). And 0x27 is open: its failed-key count and lockout are the SERVER's, and
kept through a reset (`kept_security`), so a network tester sending wrong keys locks the bus
tester out of 0x27 too for the lockout delay. Neither is preventable by a session gate — the
attempt is the authentication — only by authenticating before the request is served, at
activation. Not built: that authenticated routing activation (the OEM-specific field, or 0xE0
central security) — it would authenticate the CONNECTION, while ISO 14229's 0x27 / 0x29
authenticate the diagnostic session, which is what the requirement names; and 0x29 itself, which
the application server does not serve (the bootloader's `boot.Prog` does).

**One NetX per image** (`driver/eth/netx_up.c`): the pool, the IP instance,
ARP/ICMP/UDP, the link wait and `rand()` are brought up once, at the node's one
address; SOME/IP (`eth_netx.c`) and DoIP (`doip_netx.c`) attach to it, so a node
may carry both, and only a DoIP image links the TCP engine. What an image links
for its network is generated — `gen/loom_build.mk`'s `LOOM_NET_SRCS` — so no
node's Makefile lists those sources by hand.

## P3b status — DoIP (2026-07-18, BENCH-VERIFIED)

REQ-NET-007 on silicon: `examples/h735_doip`, the first V+NetX hybrid image — retired in #340
once `[doip]` generated the same server onto sysnode (above); its burst-correlation leg lives on
as `examples/system_full/test/doip_burst.lua`.
DoIP framing (ISO 13400-2: routing activation, diagnostic message + acks,
vehicle announcement, generic NACK) is tested V code in `comm/doip`, driving
the SAME `comm.uds.Server` the bus transport uses; `netx_glue.c` owns
ThreadX/NetX/sockets behind a four-call byte-pipe seam (since #338/#341 that seam is
`driver/eth/doip_netx.c` on the shared `netx_up.c`, generated from `[doip]`). Bench, then:
routing activation → 0x22 F190 → "H735-DK" (later the announced VIN) → 0x3E tester-present,
all pass from a WSL client through the Windows NAT on the live internal network.

Bring-up finding (the busy-network wedge): a **finite-timeout**
`nx_tcp_server_socket_accept` in a re-accept loop is a NetX trap. On timeout the
connect-cleanup returns the socket to LISTEN without repopulating `connect_ip`;
the next accept then sends the SYN-ACK itself with a null destination IP,
tripping `NX_ASSERT` in the checksum path — which parks the calling thread in an
infinite sleep **while holding `nx_ip_protection`**, starving the IP thread and
freezing all RX (reads exactly like a driver deadlock; diagnosed by per-thread
state + mutex owner over SWD). Server sockets accept with `NX_WAIT_FOREVER`
(the P1-P3a pattern); only the receive is bounded.
