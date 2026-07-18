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
- **Diagnostic writes need authentication (REQ-NET-012).** The 0x29 gate lives in
  `boot.Prog`; the application UDS server (`uds.Server.handle`) currently accepts
  `0x2E WriteDataByIdentifier` on any writable DID with no auth. Over CAN that is
  a physically-present adversary; over IP, reachability alone would grant write
  access. The app diag server needs an authenticated-session gate (the same 0x29
  primitive, or a session-based access control) before it is externally reachable.

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
via `make deps` (`NETXDUO_PIN`, alongside ThreadX). Its Cortex-M7/GNU port
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

### Driver written — builds, BENCH-UNVERIFIED (2026-07-18)

The full P1 stack is written and compiles + links clean for the H735 target
(`make -C examples/h735_net all`). It is **untested on silicon** (same posture as
`boards/h735dk/flash.c`); the bench is where the DMA/PHY/ISR timing gets verified.

- **`boards/h735dk/eth.c` + `eth.h`** — register-level ETH MAC/DMA (RM0468): RCC +
  RMII pin mux (the AF11 table above), `SYSCFG_PMCR` RMII select, LAN8742 soft-reset
  + auto-neg over MDIO, 4+4 descriptor rings, `eth_send`/`eth_recv`, `ETH_IRQHandler`.
- **`net/nx_driver_stm32h7.c`** — the NetX `NX_IP_DRIVER` command dispatch (mirrors
  the vendored RAM driver): TX linearises the packet chain → `eth_send`; the RX ISR
  signals `_nx_ip_driver_deferred_processing`, and `DEFERRED_PROCESSING` drains
  `eth_recv` into `NX_PACKET`s routed by EtherType. Copy-based, so only eth.c's
  buffers touch DMA.
- **`examples/h735_net/`** — a plain-C ThreadX+NetX app (no loom2v/CAN): packet pool
  + IP + ICMP, brings the link up and pings the gateway on a loop. Outcome is exposed
  as `net_ping_ok` / `net_ping_fail` / `net_link_up` globals to read over SWD.

Two hardware facts drove the layout: **D-cache is off** (docs/no-alloc.md), so DMA
needs no clean/invalidate; and the ETH DMA is an AHB master that **cannot reach the
DTCM** the rest of RAM sits in, so the descriptor rings + frame buffers live in a
`.eth_dma` section in **D2 AHB SRAM (0x30000000)** — a new region in `threadx.ld`,
its clock enabled in `eth_init`. The shared `boards/common/vectors.S` is extended to
IRQ61 (ETH); non-net images resolve it via a **weak** `ETH_IRQHandler` in each
board's `board.c` (separate object, so no `--gc-sections` capture).

### Bench bring-up checklist (for the H735-DK)

1. `make -C ../.. deps` then `make -C examples/h735_net flash`.
2. Plug the DK's RJ45 into a LAN with a `192.168.1.0/24` host; set the board IP
   (`IP_ADDR`) / gateway (`GATEWAY`) in `main.c` to match your subnet.
3. Halt over SWD and read `net_link_up` (auto-neg settled?) then `net_ping_ok`.
4. If link never comes up: verify the PHY address (0) and REF_CLK on PA1; if link is
   up but no ping: check the D2 SRAM clock enable and the `SYSCFG_PMCR` RMII select.
