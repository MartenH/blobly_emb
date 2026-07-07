# Architecture overview

How the pieces fit: what a Function Block talks to, where COM / the Loom /
diagnostics sit, and how a signal travels from the bus to an FB and back. For the
*why* behind each piece see `application-model.md`, `communication.md`,
`multicore-perf.md`; this is the map that ties them together.

## The stack

```mermaid
graph TB
  FB["Function Blocks (app/)<br/>pure: In signals -> Out signals + private state"]
  PORTS["ports In/Out structs (generated)"]
  LOOM["Loom scheduler (loom/)<br/>static (handler, ctx, period) table<br/>snapshots In before the call, publishes Out after"]

  subgraph xport["cross-FB transport"]
    CELL["local cell<br/>same-core FB -> FB"]
    IOC["IOC channel (osal/)<br/>lock-free seqlock / double / triple<br/>cross-core"]
  end

  subgraph bridge["COM bus bridge — generated, runs on the IO core (gen/loom_gen.v)"]
    COM["COM<br/>signal <-> PDU, TX modes, RX deadline"]
    CODEC["DBC codec<br/>(gen/, from dbc2cfg)"]
    PROT["E2E / SecOC<br/>CRC / AES-CMAC + freshness"]
    ROUTE["Router<br/>raw-PDU gateway ([[route]])"]
    DIAG["Diagnostics<br/>ISO-TP (comm/isotp) + UDS (comm/uds)"]
  end

  DRV["driver: CAN (driver/can)<br/>SocketCAN (host) · ST FDCAN HAL · AUTOSAR CanIf"]
  BUS["CAN bus(es)"]
  OSAL["OSAL (osal/): cores · time · IOC pool · pinning<br/>POSIX fork-per-core  /  ThreadX AMP"]

  FB <--> PORTS
  PORTS <--> LOOM
  LOOM <--> CELL
  LOOM <--> IOC
  IOC <--> COM
  COM <--> CODEC
  COM <--> PROT
  COM <--> DRV
  ROUTE --> DRV
  DIAG <--> IOC
  DIAG <--> DRV
  DRV <--> BUS

  LOOM -. runs on .-> OSAL
  COM -. runs on .-> OSAL
  IOC -. lives in .-> OSAL
```

Read it top-down: an **FB** only ever touches its **ports**; the **Loom** moves data
between ports and the **transport** (a local cell, or an **IOC** channel across
cores); the **COM bridge** is the only thing that touches the **driver** and the
**bus**. Everything in the bridge box is generated and runs on the IO core.

## Who talks to what

| Part | Talks to | How / via | Purpose |
|---|---|---|---|
| **Function Block** | its `ports` In/Out only | typed fields | pure transform; knows nothing of buses, cores, or other FBs |
| **Loom** | FB handlers; IOC / local cells | snapshot In → call handler → publish Out | dispatch on a period; coherent input snapshot |
| **IOC** | the Loom (app side), the COM bridge (IO side) | `ioc_read/acquire` + `ioc_write/publish` | lock-free cross-core signal transport |
| **local cell** | the Loom only | direct struct field | same-core FB→FB, no sync |
| **COM** | IOC (signals), DBC codec, E2E/SecOC, driver | encode/decode + send/recv | signal⇄PDU, TX modes, RX deadline |
| **DBC codec** | COM | generated `*_phys` / `*_set` over `[64]u8` | raw↔physical bit packing |
| **E2E / SecOC** | COM (the frame bytes) | `protect` on tx, `check`/`verify` on rx | integrity (CRC) / authenticity (MAC) |
| **Router** | the driver of another bus | forward the raw frame | gateway, no decode |
| **ISO-TP / UDS** | IOC (read live signals), driver (the diag frames) | reassemble → dispatch → segment | diagnostics request/response |
| **driver** | the COM bridge; the bus | `open/send/recv` C shim | the only hardware-touching layer |
| **OSAL** | Loom, bridge, IOC | cores, time, the shared IOC region, pinning | the platform line: POSIX or ThreadX AMP |

The two hard boundaries: an **FB never reaches past its ports** (no driver, no IOC,
no other FB), and only the **bridge + `main.v`** touch the **driver**. Everything
else is platform-independent V above the OSAL/driver line.

## Runtime topology (who runs where)

```mermaid
graph LR
  subgraph c0["core 0 — IO"]
    BR["bus bridge — polled loop, one per bus<br/>COM · codec · E2E/SecOC · router · ISO-TP/UDS<br/><i>(target: a first-class comm thread)</i>"]
  end
  subgraph c1["core 1 — app"]
    PA["partition → thread: Loom + its FBs"]
  end
  subgraph cn["core N — app"]
    PB["partition → thread: Loom + its FBs"]
  end
  SHM[("shared IOC region<br/>mmap MAP_SHARED  /  shared SRAM")]
  CAN["CAN driver ↔ bus(es)"]

  BR <--> SHM
  PA <--> SHM
  PB <--> SHM
  BR <--> CAN
```

Each **partition** is the unit of **MPU isolation**, pinned to a core; inside it runs one
or more **threads** — the OS scheduling unit (a spawned loop on host, a ThreadX thread on
target) — each a **Loom** dispatching the FBs mapped to it. An **fb names a thread** (thread
names are globally unique, so the partition is *derived* — a thread belongs to one
partition); a handler's trigger is a **period** (dispatched on its thread) or an **interrupt**
(`irq`, ISR context). *(Today loom2v generates one thread per partition; multiple threads and
`irq` handlers are the target, not yet generated. The MPU boundary is enforced on the ThreadX
target and modeled by codegen convention on the host — see `memory-protection.md`.)*

Today the **bus bridge** runs as a **polled** per-bus loop on the IO core — it drains
`recv`, DBC-decodes rx into IOC, encodes tx from IOC, and serves ISO-TP/UDS + routing. The
**target** model makes it a first-class **comm thread** per bus (rx driven by the CAN **Rx
interrupt**, tx periodic) so that *every* thread — app **and** platform — appears in the
runtime trace **by name** and the platform is never hidden (bridge / ISO-TP overhead is often
where the time goes; see `telemetry.md`). *(The comm thread, its Rx-interrupt path, and its
manifest entry are all target — today the bridge polls and the manifest names app threads
only; NM is configured but not yet generated into the bridge.)* The only shared memory is the
**IOC region**; cross-core signals cross there and nowhere else (the basis for MPU isolation).

## Data-flow paths

**Bus → FB (rx).** `driver.recv` a frame → COM matches the id → (E2E/SecOC verify)
→ DBC-decode each signal → `ioc_publish` to the channel → next cycle the **Loom**
snapshots it into the consumer FB's In port → the FB reads it in physical units.

**FB → bus (tx).** The FB writes its Out port → the **Loom** `ioc_publish`es it →
the bridge `ioc_acquire`s it → DBC-encode into the frame → (E2E/SecOC stamp) → the
PDU's **TX mode** decides whether to send → `driver.send`.

**FB → FB.** Same core → a **local cell** (direct copy in the partition state, no
sync). Different cores → an **IOC channel** (the Loom publishes/acquires; the
transport — seqlock/double/triple — is per-channel config).

**Diagnostics.** Frames on the diag id → **ISO-TP** reassembles a request → **UDS**
dispatches it; a ReadDataByIdentifier mapped to a live signal `ioc_acquire`s it from
the same IOC the FBs use → the response is re-segmented and sent. So a tester reads
an FB's output straight off the IOC.

**Gateway.** A frame on bus A whose id matches a `[[route]]` is handed straight to
bus B's channel and re-sent — never decoded to signals.

```mermaid
sequenceDiagram
  participant Bus
  participant Drv as driver
  participant Br as COM bridge (IO core)
  participant IOC
  participant Loom as Loom (app core)
  participant FB
  Bus->>Drv: frame
  Drv->>Br: recv()
  Br->>Br: (E2E/SecOC check) + DBC decode
  Br->>IOC: ioc_publish(signal)
  Loom->>IOC: ioc_acquire(signal)
  Loom->>FB: on_10ms(In snapshot)
  FB-->>Loom: Out
  Loom->>IOC: ioc_publish(Out)
  IOC->>Br: ioc_acquire(Out)
  Br->>Br: DBC encode + (E2E/SecOC stamp) + TX mode
  Br->>Drv: send()
  Drv->>Bus: frame
```

## Where each piece lives

| Layer | Directory | Hand / generated |
|---|---|---|
| Application | `app/` (per example) | hand (one file per FB) |
| Signal types / ports | `sig/`, `ports/` | generated (`loom2v`) |
| Codec / bridge / glue / tables | `gen/` | generated (`dbc2cfg`, `cfg2v`, `loom2v`) |
| Scheduler | `loom/` | framework |
| Comms | `comm/com`, `comm/e2e`, `comm/secoc`, `comm/isotp`, `comm/uds`, `comm/nm` (+ `comm/nm_can` binding) | framework |
| Observability | `comm/telem` (processor load), `comm/trace` (thread/handler trace) | framework |
| Platform line | `osal/` (cores/time/IOC), `driver/` (CAN) | framework + C shims (see `porting.md`) |
| Entry | `main.v` | hand (tiny: open channels, `gen.run`) |

The build-time tools in `tools/` turn the config + DBC into the `sig/ports/gen` code.
**`ecucheck`** validates `ecu.toml` — unknown keys with "did you mean", types, and the
cross-field rules (via the shared **`ecumodel`**, the one place those rules live so the
validator and the generator can't drift) — **before the generators that consume the config**
(`cfg2v`, `loom2v`, `sigmap`), so no config error reaches codegen. (`dbc2cfg` reads the *DBC*,
not `ecu.toml`, and runs independently.) `loom2v` also emits the trace **manifest** mapping
thread/handler ids → names. See `ways-of-working.md` for how teams operate around that, and
`configuration.md` for what each config section generates.

## Transport scope — CAN today, Ethernet later

blobly is **CAN / CAN-FD first**, but most of the stack is transport-agnostic by
construction — only a few layers actually know about CAN:

| layer | CAN-coupled? |
|---|---|
| FBs, signals, ports | no — pure transforms |
| Loom, IOC, local cells | no — dispatch + cross-core signal transport |
| COM (signal⇄PDU, TX modes, RX deadline) | no above the PDU — a PDU is just bytes |
| **driver port** (`driver/can`, `can_port.h`) | **yes** — id + dlc + data framing |
| **codec** (`gen/`, from DBC) | **yes** — DBC is a CAN/LIN description |
| **diagnostics** (`comm/isotp` + `comm/uds`) | **yes** — ISO-TP is CAN transport |
| **NM** (`comm/nm` + `comm/nm_can`) | the state machine is **not**; the binding is |

Adding **automotive Ethernet** later is therefore not a rewrite — it slots in
**below the COM/PDU line** as a second transport:

- a generic **PDU transport** port beside `can_port.h` (CAN one backend, UDP another) —
  the role AUTOSAR splits into PduR/SoAd;
- **SOME/IP** or signal-over-UDP for data (config from ARXML/FIBEX, not DBC);
- **DoIP** for diagnostics (the Ethernet counterpart to ISO-TP/UDS);
- a sibling **`comm/nm_udp`** (UDP-NM) over the same NM state machine, if NM applies
  on that link at all.

None of the Ethernet side is built — this section marks the **seam** so new code
doesn't deepen the CAN assumptions needlessly. The module naming already reflects it:
`comm/nm` (transport-agnostic state machine) vs `comm/nm_can` (the CAN binding).
