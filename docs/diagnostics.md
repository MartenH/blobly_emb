# Diagnostics — fault memory, the diagnostic server, parameters (plan)

> Status: PLAN (2026-09-27), nothing below is built unless it says so. It joins three issues that
> are one feature seen from three sides — #286 (rx status), #287 (faults → DTCs), #288 (parameters /
> variant coding) — and the prerequisites none of them names. Requirements are derived from
> SYS-REQ-DIAG-001 (agreed) in rung R0, extending the two drafts `requirements/diag.toml` already holds
> (REQ-DIAG-001/002); until then this page is the shape to argue with.
>
> **What this page settles, and what it leaves to the rungs.** It fixes the *shape*: which component
> owns what, which way data crosses threads and cores, what is stored, what the tester sees, and the
> order of work. Mechanism details below that level — exact handshakes, id derivations, state
> precedences — are stated where a reviewer found a hole, and are otherwise settled in each rung's
> PR, where tests pin them.

A production ECU is serviced through its diagnostic interface: the workshop reads what went wrong
(DTCs with a snapshot of the conditions), clears it after the repair, and codes the vehicle variant.
blobly_emb has the request/response plumbing for a handful of services and none of the rest. This
page is the plan to close that, in rungs that each ship and verify on their own.

## 1. Where we actually are

As of R4c, R2's first steps and R6a — the rows R0 through R4c, R2 and R6a changed say so; the rest is the state the plan started from.

| Piece | State | Where |
|---|---|---|
| UDS services | 0x10, 0x11 (two-phase: answered, then reset), 0x22, 0x27 (R1b), 0x28, 0x2E, 0x3E; everything else answers 0x11. On the host 0x11 resets the DIAGNOSTIC state only (R1); a real reset is R2. Which of them a node answers, in which sessions and behind which 0x27 level, is its **service table** (`[uds] services`, §3.1); absent, the default set — every service the build performs, in its default sessions | `comm/uds/uds.v`, `tools/loom2v/gen_diag.v` |
| Session model | enforced (R1): starts in default, S3 returns to it (`s3_ms`), every session request relocks security (re-entry included, R1b), and returning to default re-enables the communication 0x28 disabled; the programming session is refused until the R2 handoff | `comm/uds/uds.v`, `comm/diag/diag.v` |
| DIDs | 16 × ≤32 B static table; 0x22 reads several DIDs per request (R1); per-DID `read` / `write` session and security gates | `comm/uds/uds.v` |
| NRCs | 0x11 0x12 0x13 0x14 0x22 0x24 0x31 0x33 0x35 0x36 0x37 0x7F in ISO 14229-1's evaluation order (R1; the 0x27 ones R1b); functional requests withhold 0x11/0x12/0x31/0x7E/0x7F; no 0x7E (no subfunction is session-gated yet) and no 0x78 (R6/R7) | `comm/uds/uds.v` |
| Security access 0x27 | served on the host (R1b): levels from the DID gates, one key per seed, attempt limit + lockout delay (the count survives an ECU reset), keys through the injected `SecurityOps` (the host bridge injects the reference key; a ThreadX target the board's seam, `boards/common/diag_board.c`); the bootloader keeps 0x29 | `comm/uds/uds.v` |
| UDS on the **target** | R2, first steps: `[isotp]` on the ThreadX comm thread (the one on `[telemetry].bus`) — the same `comm/diag.Connection` the host bridge runs; constant DIDs, and live DIDs on the node's own local OUTPUTS (the cells the comm thread already reads — an input's cell is its FB's, one reader per cell); 0x27 with a TRNG seed from the board (`boards/common/diag_board.c`, weak) and the OEM's `diag_sa_key_ok` — no default is linked, so a gated node without one fails to link; blobly_net's public reference key only by name (`[uds] security_key = "reference"`, the bench's); bench-verified on all three `system_full` CAN nodes — domain (H755, `examples/system_full/test/diag_domain.lua`), the gateway sysnode (H735) and zone_a (H723, on the CAN-FD edge bus with classic-sized ISO-TP, TX_DL = 8) (`diag_nodes.lua`). 0x11 answered, then performed by the comm thread once the controller has sent the answer (bounded `tx_idle`, REQ-BOOT-012), the 0x27 failed-key counts carried across it in a reset-surviving keep cell (`diag_board.c`, D3 SRAM4), so a reset between guesses buys nothing — on domain and zone_a by `diag_domain.lua` / `diag_nodes.lua`; on sysnode, whose 0x11 is gated behind level 1 (a `[doip]` node, REQ-NET-012) so a CAN tester locked out cannot reset it, by `doip_sysnode.lua` (a DoIP unlock earned first, the keys spent from CAN; bench-run 2026-10-02). Not yet: live DIDs on inputs, the failed-key count across a power cycle, 0x28, the programming handoff | `tools/loom2v/gen_diag.v` |
| UDS config | split along the standards: `[uds]` — the ISO 14229 server (`s3_ms`, `security_attempts`, `security_delay_ms`, `security_key`, the `services` table) — and its transports, `[isotp]` (ISO 15765-2: `bus`, `rx_id`, `tx_id`, `functional_id`, `bs`, `stmin_ms`; one per node, a table) and `[doip]` (ISO 13400); + `[[did]]` (ascii / bytes / signal / writable, `read` / `write` gates). The old `[[isotp]]` array carrying server keys is refused with the move it needs | `tools/ecucheck/gen.v`, `tools/ecumodel/model.v` |
| Rx signal status | `status = "RxStatus"` (never_received / ok / timeout / integrity) and the E2E `lost` count, bridge-owned (R3a; on CAN the host bridge only, on the SOME/IP receive path both, bridge-owned and never on the wire, on the host and the ThreadX eth thread alike, and sysgen gives both to a generated E2E receiver); the COM deadline runs from bridge start (re-arming it on NM wake is R5's: the host bridge has no NM) and from a frame that failed its check; E2E has its own sender-loss timeout, required on every received E2E frame, refreshed only by a valid message and independent of the COM deadline (R3b; on CAN and, since #299, on the SOME/IP receive path — host and ThreadX — where an eth rx signal carries the same `status`); the target's CAN comm thread rejects status, rx deadlines and E2E ("phase 6b-2b", R5) | `tools/loom2v/gen_com.v`, `gen.v` |
| Fault memory / DTCs | R4a + R4b: `[[fault]]` generated on the host — the FB's fault port, debounce on its thread with monotonic counters, the fault memory on the diagnostic bridge (status byte through operation cycles from `[fault_memory] cycle`, confirmation, aging, clears by generation, 0x85 suppression), 0x19 01/02/0A, 0x14, 0x85; RAM only. R4c: signal-status faults (`signal` / `on` = timeout, integrity, lost), the bridge as detector. R6a: FB-tested faults on a **ThreadX target** — the same debounce on the FB's thread, the same `comm/fault` memory on the comm thread (D2), the report / control cells on the byte IOC (`boards/common/iocb.c`), 0x19 01/02/0A, 0x14, 0x85 through the one server (DoIP included); RAM only; demonstrated on `system_full` zone_a (`test/faults_zone_a.lua`). Not yet (the rest of R6): persistence, freeze frames, extended data, displacement, 0x19 03/04/06, signal-status faults on the target (needs R5), faults on a satellite core or in a multi-thread partition | `comm/fault/fault.v`, `tools/loom2v/gen.v`, `gen_com.v` |
| Persistence | journal engine + `persist = "now" / "shutdown"` signals, ThreadX only, one journal per node, 20 B records with 634 B chains; DID write path (NvM "P4") not built | `nvm/`, `tools/loom2v/gen_nvm.v` |
| Operation cycle / ECU state | the fault memory's operation cycle follows a declared bool signal on the host (`[fault_memory] cycle`, R4b); on a ThreadX target it follows NM — wake begins it, bus sleep ends it (D3's default, R6a) — and on either owner `cycle = "power"` makes it the power cycle (a node with neither NM nor a cycle signal); a cycle SIGNAL on the target is not generated yet; `ecu/` (lifecycle, mode arbiter) is still an unused library; NM states exist | `tools/loom2v/gen.v`, `gen_com.v`, `ecu/`, `comm/nm/` |
| Cross-thread transports | last-value cells only (seqlock / double / triple, xioc); `bulk` is the one FIFO | `osal/`, `boards/common/` |
| Tester (blobly_net) | client: 0x10 0x22 0x2E 0x3E, **0x27 with a reference key (seed XOR 0xFF)**; since N1 / N2 also 0x11 0x14 0x28 0x85, functional addressing, and 0x19 01/02/0A decoded into a DTC model with named status bits (Lua `diag:dtcs` / `supported_dtcs` / `dtc_count` / `clear_dtcs` / `dtc_setting`, `check.dtc`); its simulated server answers 0x19 01/02/0A, 0x14, 0x85. Not yet: 0x19 03/04/06 (N3), a DTC view (N4) | `blobly_net modules/uds` |

Three doc claims were ahead of the code; R0 (#292) and R1 (#291) corrected them: `docs/autosar-comparison.md`
marked diagnostics "✅ have" (only the request/response half exists), `docs/communication.md` called
the ISO-TP handler a positive-response echo next to "UDS ✅", and `docs/nvm.md` opened with "Nothing
is built" while P1/P2 and chains were.

## 2. Principles (the ones every rung is checked against)

1. **Faults and parameters reach an FB through ports, not an API.** An FB writes a test result to an
   Out field and reads a parameter from an In field — the same rule persistence follows
   (`docs/nvm.md`: "persistence through signals, not an API"). No `SetEventStatus`, no return codes
   — and nothing comes back: an FB never reads its fault's status (§3.3).
2. **Diagnostics is a platform service, not an FB.** Like NM, trace and NvM, the diagnostic server
   and the fault memory are modules the generator splices into a comm thread — **one** of them: the
   comm thread of the image that serves the node's one `[isotp]` connection's bus (on the host, that bus's bridge). It is the single
   writer of the fault memory and, on the target, already the owner of the journal. Every other
   detector — a bridge on another bus, an FB thread, the satellite core — reaches it through ordinary
   IOC / xioc cells it alone reads, so the single-writer rule holds without a lock.
3. **Everything is declared in `ecu.toml`, validated at generation, and cross-checked by syscheck.**
   A connection's *physical* request / response ids are unique per bus (reuse on electrically
   separate buses is fine), while a *functional* id is deliberately SHARED by every server on its bus;
   DIDs and DTC numbers are unique per *node* — every ECU may expose the VIN DID 0xF190, and the
   same DTC value can mean something on two ECUs. **One diagnostic server per node** (one
   `[uds]` server, on its `[isotp]` connection, carrying its DIDs and faults — R1 already refuses more): that is how ECUs
   are addressed in practice, and it keeps the fault memory, its clear epoch and 0x85 with a single
   owner. A second server on another bus is out of scope (§6). The manifest keys DIDs and DTCs by
   node plus identifier.
4. **No heap, fixed tables sized at generation**, the same as every runtime layer.
5. **Sim first, then silicon, and a tester to prove it.** Each rung has a host proof, and the target
   rungs end on `examples/system_full` driven from blobly_net over the CANsub. blobly_net is the
   *oracle*, not shared code (`blobly_net docs/blobly_emb_synergies.md`), so the plan carries tester
   rungs of its own (§4).
6. **Our own words.** "diagnostic server", "fault", "fault memory", "test result", "operation cycle"
   — not DCM/DEM/monitor/event names as ours.

## 3. Design

### 3.1 The diagnostic server (UDS, ISO 14229-1)

`comm/uds` grows from a request echo into a server with a **service table generated from config**.
The configuration follows the standards' layers: **`[uds]` is the server** (ISO 14229 — one per
node), and **its transports refer to it**: `[isotp]` carries it on CAN (ISO 15765-2), `[doip]` on
Ethernet (ISO 13400, a ThreadX target). A node has one server and so one session, whichever
transport a request arrives on:

```toml
[uds]                           # ISO 14229: the node's ONE diagnostic server
s3_ms             = 5000        # session timeout (default 5000)
security_attempts = 3           # 0x27 failed keys before the lockout (default 3)
security_delay_ms = 3000        # 0x27 lockout delay (default 10000)
security_key      = "reference" # a target only: blobly_net's bench key; absent = the OEM's diag_sa_key_ok

[uds.services]                  # optional — absent = the default table (below)
"0x10" = {}
"0x11" = { sessions = ["extended"] }
"0x22" = {}
"0x27" = {}
"0x2E" = { sessions = ["extended"], security = 1 }
"0x3E" = {}

[isotp]                         # ISO 15765-2: the server on CAN (one connection per node)
bus           = "compute"
rx_id         = 0x7E0
tx_id         = 0x7E8
functional_id = 0x7DF           # optional: functional requests (single frame), shared per bus
bs            = 8
stmin_ms      = 0

[[did]]
id      = 0xF190
ascii   = "BLOBLY0000000001"
read    = { session = ["default", "extended"] }
[[did]]
id      = 0xF1A0
signal  = "VehicleSpeed"
[[did]]
id      = 0x0100
param   = "TrailerBrakeFitted"  # §3.4
write   = { session = ["extended"], security = 1 }
```

**The service table** is AUTOSAR Dcm's idea in our words: which services the server answers, where
and behind what. A row is keyed by its SID in hex and may carry `sessions` (`default` / `extended` /
`safety`, the names a `[[did]]` gate uses; absent = the service's default sessions) and `security`
(a 0x27 level; absent = none). The same table configures the server on every owner — the host bus
bridge and the ThreadX comm thread both go through `conn_init_lines` (`tools/loom2v/gen_diag.v`),
and a DoIP request reaches that same server — and comm/uds checks it in dispatch, after "is the
service wired" and in ISO 14229-1's order: **0x11** serviceNotSupported for a service the table
leaves out (withheld for a functional request, as before), **0x7F** serviceNotSupportedInActiveSession
outside its sessions, then **0x33** securityAccessDenied below its level — before the length check
and any per-DID gate. Every session entry relocks, so a service-level unlock lasts the session it
was earned in, as a DID's does.

- **Absent = the default table, byte for byte**: no rows are generated (`nservices = 0`), and the
  server answers exactly what it did before the table existed — every service the build performs,
  0x27 / 0x28 / 0x85 in the non-default sessions only, everything else in every session, no
  service-level security. `comm/uds` `test_the_default_table_is_the_old_behaviour` pins every SID in
  every session against the old rule written out literally.
- **What a build performs is one statement** (`diag_unbuilt`): 0x10 / 0x22 / 0x2E / 0x3E always;
  0x11 on both owners (each performs the reset); 0x28 on the host only (nothing on the target gates
  its frames on it yet); 0x14 / 0x19 / 0x85 with a `[[fault]]` memory (on both owners since R6a); 0x27 when
  a `[[did]]` gate or a service row names a level. The wiring follows it (`serves_reset`,
  `serves_comm_control`) and generation refuses a row it names — **a table never claims a service
  that does nothing**. A row also grants nothing the owner did not wire: comm/uds answers 0x11 for a
  listed service with no seam behind it.
- **Refused at generation**, each naming `[uds]`: a service the build does not perform (above) or
  comm/uds does not implement; the programming session (the bootloader's); the default session for
  0x27 / 0x28 / 0x85 (ISO 14229-1 runs them only in a non-default one); a 0x10 row without the
  default session, or any row reachable only outside it with 0x10 left out; a `security` level on
  0x10 / 0x27 / 0x3E (how a tester reaches, unlocks and keeps a session) or on a row not allowed in
  the extended session (the only one an application server unlocks in), and a 0x27 row without it;
  a table leaving out 0x27 while a level is gated, 0x22 while a DID exists or 0x2E while one is
  writable; a DID gate sharing no session with its service's row, or naming another 0x27 level
  than the row (one unlock cannot satisfy both); more rows than `uds.max_services` (16).
- **...and on a `[doip]` node, naming `[doip]`** (REQ-NET-012; `tools/doipcfg`, so syscheck
  refuses the same at the system): NO table at all (the default one serves 0x11 to anyone); a row
  for a service that changes ECU state — anything but 0x10 / 0x19 / 0x22 / 0x27 / 0x2E / 0x3E —
  without a `security` level; a writable DID whose own write gate and the 0x2E row both name no
  level; and `security_key = "reference"` unless `[doip] allow_bench_key = true` (docs/net.md).
  The example above is a CAN-only node's: on a `[doip]` node its 0x11 row needs `security = 1`.
- **Migration** (no silent translation): the old `[[isotp]]` array — and a server key (`s3_ms`,
  `security_*`) or `name` in `[isotp]` — is refused by `ecumodel.validate` (so by ecucheck and
  loom2v alike) with the move it needs: write `[isotp]` as a table without `name`, and move the
  server's keys to `[uds]`.

What it adds, all table-driven so an unsupported path answers the right NRC rather than a guess:

- **Sessions** default (01) / extended (03) / programming (02), **starting in default**. An
  application server does not accept programming until the bootloader handoff exists — the boot cell
  plus a reset into `boot.Prog`, which alone serves erase / download (R2); until then 0x10 02 is
  refused rather than answered with a session that cannot program. The handoff is **two-phase like
  0x11** (below): the 0x50 response must leave the CAN controller before the reset into the
  bootloader, and R2 proves the tester receives it. Then S3 return-to-default; **every session
  transition — explicit or by S3 — relocks security** (REQ-BOOT-013's rule, and what `boot.Prog`
  already does), so an expired unlocked session cannot be re-entered without a new seed / key; and per-service, per-subfunction and per-DID session and
  security gating, answered in ISO 14229-1's NRC-evaluation order: 0x11 / 0x7F, 0x12 / 0x7E, 0x13,
  0x22, 0x24 (requestSequenceError), 0x31, 0x33 (securityAccessDenied).
- **Multi-DID 0x22** (several DIDs per request, response-size checked → 0x14 responseTooLong).
- **Functional addressing**, with the suppress-positive-response rules and the negative responses
  a functional request must NOT answer: 0x11, 0x12, 0x31, 0x7E and 0x7F (a broadcast into a gated
  service stays silent on every ECU).
- **Response pending (0x78)** for anything that waits on flash (0x2E of a persisted DID, 0x14): the
  server answers 0x78 inside P2 and completes within P2*; the comm thread never blocks. The final
  answer reflects durability: if the journal refuses the write (capacity, programming, read-back —
  `nvm.Journal.put` returns false) the previous durable state stands and the request ends with **0x72
  generalProgrammingFailure**, never a positive response for data that was not stored. Both services
  get a fault-injection test.
- **0x27 SecurityAccess** with seed from the board TRNG, attempt counter + delay (0x35/0x36/0x37,
  0x24 for a key sent before its seed) that **survives a reset** — the failed-key count is kept
  across an ECU reset (R1b) and persisted across a power cycle on the target (R2), with the lockout
  applied at boot only while it is non-zero, since an in-RAM counter alone is bypassed by
  power-cycling between guesses; a clean reset or boot never waits — and the key check behind an **injected,
  platform-neutral interface** (a fixed function-pointer ops struct handed to the server, the shape
  `boot.Prog.rng` already uses), so `comm/uds` stays free of any `fn C` — the OEM algorithm and any
  board code live in the target glue, below the backend line. The sim and bench use the reference key blobly_net's client already
  implements (seed XOR 0xFF), so the two sides unlock with ONE algorithm. 0x29 stays the
  bootloader's programming authentication.
- **0x11 ECUReset** (hard / soft), **two-phase**: the server records the request and answers; the
  owner resets only once the response has left the CAN controller, with a bounded drain — the
  bootloader's `reset_pending` path, where REQ-BOOT-012 records that waiting for ISO-TP idle alone
  still lost the response on the H755 bench. It is proven on the target (R2), not just the host; **0x28 CommunicationControl**
  (gates COM tx the way NM already does), **0x85 ControlDTCSetting** (§3.3).
- The bootloader's `Prog` keeps composing `uds.Server`, so it inherits session/NRC fixes for free.

It runs on the **target** as a comm-thread module — which first meant lifting the ThreadX refusal of
the ISO-TP connection (R2): ISO-TP links in the comm thread, rx by id, tx `tx_ready`-gated, exactly as the trace
dump already streams ISO-TP from that thread.

### 3.2 Rx status (#286)

The reserved `valid` bool becomes a status the bridge owns and publishes with the value — still one
field, still no API:

```v
pub enum RxStatus { never_received ok timeout integrity }
```

`never_received` — deliberately the ZERO value, so a signal nobody has published yet (and a
freestanding image, where no field initialiser runs) reads as not-yet-received rather than healthy —
until the first good decode, `timeout` past the deadline, `integrity` on an E2E or
SecOC failure, and E2E `lost` counted rather than hidden. The status is the **most recent
condition**: `integrity` holds until a good frame (→ `ok`) or until the deadline passes with none
(→ `timeout` — silence is then the newer fact). The integrity *fault* is not lost by that
transition: it was already reported to its debounce when the rejection happened. R3 tests the
corrupt-frame-then-silence sequence. It is
both an FB input (substitute vs. safety reaction are different responses) and a **fault source**: a
signal can declare its own DTCs for timeout and integrity with no FB code (§3.3), because the bridge
is the detector. The target half needs the comm thread to run rx deadlines and E2E/SecOC — the
"phase 6b-2b" gap loom2v names today — so #286 lands host first and target in its own rung (R5).

### 3.3 Faults and fault memory (#287)

**Declaration.**

```toml
[[fault]]
name     = "BrakePressureImplausible"
dtc      = 0x523000                                 # C1230-00: 3-byte DTC, ISO 14229-1 D.1
from     = "BrakeCtrl.on_10ms"                      # the HANDLER that tests it (an FB may have several)
debounce = { kind = "counter", fail = 3, pass = 5 } # or { kind = "time", fail_ms, pass_ms }
enable   = ["SupplyOk.ok"]                          # enable conditions = bool signal fields
freeze   = [0xF1A0, 0xF1A1]                          # snapshot = declared [[did]]s (DID/data pairs in 0x19 04)
confirm  = 1                                        # failed operation cycles to confirm
aging    = 40                                       # passing cycles before a confirmed DTC ages out
priority = 2                                        # for displacement when memory is full

[[fault]]
name     = "SpeedMsgTimeout"
dtc      = 0xC10000             # U0100-00 (lost communication)
signal   = "VehicleSpeed"   # detector = the bridge: rx status timeout (§3.2), no FB code
on       = "timeout"        # or "integrity"
```

**The FB side** is one generated Out field per fault it owns:
`outp.fault.brake_pressure_implausible = .failed` (or `.passed`; untouched = `.not_tested`). That is
the *pre-debounce* result.

**Reporting is one-way.** The FB gets no return value, never reads a status byte, and is never told
that a DTC was confirmed, cleared or suppressed. What reacts to a clear, a cycle start or 0x85 is the
generated debounce on its thread (the way back, below), not FB code. That is deliberate: the fault
memory is diagnostic bookkeeping that a tester may erase (0x14) or freeze (0x85), so behaviour keyed
off it would switch off at a workshop clear while the fault is still present. **An FB reacts to what
it detects** — a degraded mode keys off its own detection, or off a signal, like any other input —
never to what the fault memory recorded. It follows that **an FB reports the current result on
every dispatch and keeps no latch of its own**: the fault's *history* (failed since clear,
confirmed) is the fault memory's to keep, and neither debounce kind latches a failure. A
self-latching FB would report `.failed` again right after a 0x14 and bring the DTC
straight back, and no hook exists to reset it — none is needed as long as FBs report without memory.
The one status that may leave the fault memory is the warning-indicator request (bit 7): published
as an ordinary signal, for whatever drives a lamp to read as an input, and added only when a lamp
needs it.

**Debounce runs on the producing thread**, generated into the Loom right after the handler, every
dispatch — a pre-debounce result must never cross a last-value cell, because a consumer that reads
slower than the FB writes would miss results and an alternating fail/pass would never reach its
threshold. What crosses to the fault memory is the **debounced state plus monotonic counters** in an
ordinary IOC cell: `{ applied_gen, test_failed, qualified_fail_count, qualified_pass_count, tested,
snapshot }`. The consumer turns counter deltas into occurrences, per fault, keyed by `applied_gen` —
the clear generation the producer has acted on (below): between two readings of the same generation
the delta is the difference; the FIRST reading of a new generation counts from zero, because the
producer reset its counters when it applied that generation. A reset is never read as a negative
delta or a phantom occurrence, and occurrences between the reset and the first read are not lost.
`snapshot` is the **freeze frame**, copied by the generated debounce at the qualifying dispatch from
the values its thread reads — so it describes the instant of qualification, not a later pass of the
consumer. Its size is bounded by the cell (the IOC payload limit, minus the fields above); a larger
snapshot needs the `bulk` path and is refused by generation until then. Nothing is lost across a slow read and
**no queued transport is needed** (the alternative, a per-thread event FIFO on the `bulk` rings, is the fallback
if a use case needs the exact order of qualifications — decision D1).

**The way back.** Debouncing lives on the producer, so everything that must restart or pause it has
to reach the producer too — or a 0x14 clear is undone by the next read of a still-failed cell. The
fault memory publishes a **control cell per fault-owning FB** — as built in R4b, one report cell and
one control cell per FB (single writer each: that FB's thread / the diagnostic bridge — the IOC is
SPSC, so one shared cell with several readers is not an option): a *clear generation* **per fault** (a per-DTC 0x14 bumps only its faults'
generations, 0x14 FFFFFF bumps them all; every clear is a FRESH 16-bit generation, so no report made
before it can count, and a clear that could not get one — its producer silent for 32767 clears — is
refused with 0x22 rather than reuse a generation; a bump resets that fault's counters and debounced state, and the producer echoes
it as `applied_gen`). **0x85 suppression** rides the same generation: while off, the fault memory
lets its baselines follow the counters and changes no status, and turning it on starts a FRESH
generation exactly as a clear does, leaving the status alone — so the producer restarts its
debounce, and neither a report produced while off nor the debounce state accumulated meanwhile is
applied after "on". (Until #364 "on" was consumer-side only — the next reading was a baseline — so a
counter left saturated by a failure the off window saw qualified on the first failed result after
"on", recording a failure the requirement forbids; seen on the bench as status 0x2E.) The accepted
cost: a failure held across "on" is recorded only once it debounces again; a cycle begun while off
gets fresh cycle bits at "on". "On" cannot be refused (a session end turns it on too), so a fault
whose producer has been silent for 32767 generations keeps the one it has. *As built in R4a*
(`comm/fault`), **operation-cycle boundaries** stay on the consumer side: they change status bits
only and bump no generation, so no old-generation drain is needed on the host (a qualification at a
boundary can land one pass late). The persistence-grade cycle-END barrier
remains R6's (§7). The
per-fault generations are bounded by the cell too, which caps the faults one FB may own (8). A
producer on a **satellite core** needs the same cell to flow owner → satellite, which the target does
not support today (loom2v rejects any signal INTO a satellite partition); R6 adds that reverse xioc
path, or faults are declared owner-core-only until it exists (as built in R6a: owner-core only — a
fault on a satellite partition is refused, as is one in a multi-thread partition). Enable conditions are evaluated on the producer
itself — they are signals, readable there like any input — so a fault whose condition is false stops
counting instead of qualifying the moment the condition returns.

**The fault memory** is a comm-thread module (decision D2), the single writer of:

- the **ISO 14229-1 status byte** per DTC — bit 0 testFailed, 1 testFailedThisOperationCycle,
  2 pendingDTC, 3 confirmedDTC, 4 testNotCompletedSinceLastClear, 5 testFailedSinceLastClear,
  6 testNotCompletedThisOperationCycle, 7 warningIndicatorRequested — with the availability mask
  generated from what the ECU supports;
- the **operation cycle** — begins on NM wake and ends on bus-sleep by default, or on an explicit
  declared signal (e.g. an ignition input) (decision D3); cycle boundaries age and qualify entries. A
  node with neither NM nor a declared cycle signal **fails generation** when it declares ANY fault —
  every DTC's status carries the this-operation-cycle bits, which would otherwise never reset, and
  pending would never confirm or age — unless it declares `[fault_memory] cycle = "power"` (R6a):
  the cycle is the power cycle (AUTOSAR's POWER cycle type), begun when the owner starts and ended
  by power-off. That is a statement, not a default: while the memory is RAM only its end is never
  observed, so within it nothing leaves pending or ages — persistence (R6) records the shutdown.
  As built, the host bridge takes a signal or "power" (it runs no NM) and a ThreadX target NM or
  "power" (its comm thread's lean receive decode keeps no bool a cycle signal could be read from);
- **entries**: DTC, status, occurrence counter, **failed-cycle counter** (what `confirm` counts —
  occurrences are not cycles), aging counter, first/last failure cycle, and the
  **freeze frame** — the `snapshot` the producer captured at qualification (above), serialised as the
  declared DIDs' records, which is what 0x19 04 returns and what the tester decodes;
- **extended data records** (occurrence and aging counters) and **displacement** by priority, then
  age, when the memory is full — persisted as a **tombstone** of the evicted entry written before its
  replacement (the journal has no delete, so an evicted entry would otherwise come back at the next
  mount); on recovery a tombstone wins over the entry it names;
- **suppression**: enable conditions (signals), 0x85 DTCSettingType off, and — through the same
  signal mechanism — under-voltage.

**Storage** is the existing journal (decision D4): each DTC's **whole entry** — status, counters and
freeze frame — is ONE value, a **chained record** (built, up to 634 B) replaced as a unit. The
journal is power-loss-atomic per value, so an entry is always one coherent version; splitting status
and snapshot into separate values would let a power loss between the two writes restore new status
with an old or missing snapshot. Writes happen at qualification, cycle end and clear, so rewriting the
entry whole costs little wear. A group clear (0x14 FFFFFF) must not be half-visible after a failed
write, so it is ONE value: a persisted **clear epoch**, which every entry records when written; on
restore an entry older than the epoch counts as cleared, and the stale rows are compacted away later.
A per-DTC clear is a single entry write, atomic already. Each entry's block id is **derived, not assigned by declaration
order**: from the server, the DTC and a hash of the entry's serialized schema, with collision
handling — the rule `docs/nvm.md` already applies to persisted signals, so a firmware update that
reorders faults or changes a snapshot cannot restore one DTC's evidence into another. The entry also
carries its DTC, checked on restore. The diagnostic block ids join
the generated schema keep-set — today mount **prunes** every id that is not a persisted signal, so
without that every restored DTC would be discarded before the fault memory reads it — and the
capacity/wear checks. A freeze frame's size is bounded by what the tester can receive, not by the
chain: generation rejects a snapshot whose 0x19 04 response (SID, subfunction, DTC, status, record
headers + data) exceeds the transport's message limit (ISO-TP 520 B today); a separate sector region stays
available purely for wear isolation. This resolves the contradiction inside `docs/nvm.md`, which both
prefers a second wide-record journal and says chains dissolve it — chains exist now, so the second
journal is not needed. Writes are event-driven (qualification, cycle end, clear), never cyclic, and
ride the same bus-sleep flush choreography as persisted signals.

**UDS side:** 0x19 subfunctions **0x01** (count by mask), **0x02** (DTCs by mask), **0x03** (snapshot
identification), **0x04** (snapshot by DTC), **0x06** (extended data by DTC), **0x0A** (supported
DTCs); **0x14** ClearDiagnosticInformation (group 0xFFFFFF and per-DTC, 0x78 while the journal
writes); **0x85** ControlDTCSetting on/off.

**System level:** syscheck rejects a DTC number used twice **within one diagnostic server** (never
across servers — the same value is legitimate on two ECUs) and a freeze-frame DID the producing thread
cannot read; the `.blobnet` manifest carries the DTC table so the tester names DTCs without a
separate description file.

### 3.4 Parameters / variant coding (#288)

```toml
[[param]]
name    = "TrailerBrakeFitted"
type    = "bool"             # or fields, like [[signal]]
default = false              # compiled in; used until coded
to      = ["BrakeCtrl"]
range   = { min = 0, max = 1 }   # validated at 0x2E → NRC 0x31 before storage
apply   = "next_dispatch"    # or "reset" for parameters that shape start-up
```

The DID binding has ONE source: the `[[did]]` that names the parameter (`param = ...`, §3.1);
`[[param]]` does not repeat it. The consumer sees a **read-only In field**, indistinguishable from a signal that never changes. The
value is a persisted record with a compiled default; the write path is the DID binding NvM calls P4
("writable DIDs backed by blocks"), which is **built first** in this rung — it does not exist yet.
Parameters are runtime-only: generation stays one binary for all variants.

## 4. Rungs

Each rung ships as its own PR(s), with requirements first (`requirements/diag.toml`), a host proof,
and — from R2 on — a bench verification on `examples/system_full` recorded in
`requirements/verifications.toml`.

| Rung | Scope | Proof | Depends on |
|---|---|---|---|
| **R0** | Requirements for everything below (REQ-DIAG-*); correct the three over-claiming docs; decide D1–D6 (done: §5) | `make trace-check` | — |
| **R1** | Server core on the host: the server settings (then in `[[isotp]]`, now `[uds]`) (`functional_id`, `s3_ms`), sessions from default + S3, gating tables, NRC set + evaluation order, multi-DID 0x22, functional addressing, 0x11, 0x28 (0x78 arrives with the first service that waits on flash, R6/R7) | unit tests + `examples/overspeed` e2e vs the blobly_net client | R0, N1 |
| **R1b** | 0x27 SecurityAccess with the board key seam + blobly_net's reference key | unit tests; e2e with the existing net 0x27 client | R1 |
| **R2** | UDS on the **target**: `[isotp]` on the ThreadX comm thread; 0x11 with the bounded controller drain; the programming-session handoff into the bootloader | bench: sessions, DIDs, 0x27 (incl. reset between failed attempts), 0x11 answered then reset, app → boot handoff, on `system_full` domain via CANsub | R1, R1b |
| **R3** | Rx status (#286) on the host: `RxStatus`, bridge-owned, integrity latch, E2E `lost` counter; `valid` migrated | host e2e (timeout / integrity / never_received) | R0 |
| **R4** | Faults on the host: `[[fault]]`, FB fault port, generated debounce, fault memory in RAM, status byte, operation cycle, enable conditions, 0x19 01/02/0A, 0x14, 0x85; signal-status faults from R3; syscheck DTC uniqueness | host e2e: fail → pending → confirmed → cleared → aged | R1, R3, N2 |
| **R5** | Target COM checks ("phase 6b-2b"): rx deadlines + E2E/SecOC on the comm thread, so R3's status reaches FBs on silicon (the signal-status DTCs on silicon are R6's, once faults run on the target) | bench: pull a sender, corrupt a frame, FB sees the status | R2, R3 |
| **R6** | Fault memory persisted (diagnostic ids in the prune keep-set) + freeze frames (size-checked against the response limit) + extended data + displacement; 0x19 03/04/06; faults on the target, incl. the owner → satellite control path. **R6a (built):** FB-tested faults on a ThreadX target, RAM only — the memory on the comm thread, cells on the byte IOC, cycle from NM or "power", 0x19 01/02/0A / 0x14 / 0x85 | R6a: generation tests (`tools/loom2v/fault_target_test.v`) + bench on zone_a (`test/faults_zone_a.lua`: fail → confirmed → passing → cleared, 0x85 off records nothing). Rest: bench: fault, power-cycle, read back with snapshot; clear with 0x78 | R2, R4, N3 |
| **R7** | Parameters (#288): NvM P4 DID write path, `[[param]]`, range check, `apply` | bench: code a variant, reset, FB sees it | R1b, R2 |

R3 and R1 can run in parallel; R5 and R6 can run in parallel after R2.

**blobly_net rungs** (in blobly_net, sequenced to land just before the emb rung that needs them):

| Rung | Scope | Needed by |
|---|---|---|
| N1 | Client: functional addressing, 0x11, 0x28, 0x85 helpers, the missing NRC names (0x24 0x36 0x37 0x72 0x7E …) | R1 |
| N2 | 0x19 01/02/0A decoded into a DTC model with named status bits; 0x14; Lua `uds.read_dtcs/clear_dtcs`, `check.dtc(...)` | R4 |
| N3 | 0x19 03/04/06 (snapshot + extended data) decoded against the manifest's DTC table | R6 |
| N4 | GUI: a DTC view in the Diagnostics panel (read, clear, snapshot) | R6 (not blocking) |

(0x27 needs no tester rung: net's client and its reference key already exist.)

## 5. Decisions (made in R0)

Decided by the maintainer on 2026-09-28: each one as recommended here.

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | How debounced results cross threads | monotonic counters in a last-value IOC cell | no new transport; lossless for occurrences; the `bulk` FIFO remains the fallback |
| D2 | Where the fault memory runs | the comm thread | it already owns the journal and the bus; one writer, no lock |
| D3 | Operation cycle source | NM wake → bus-sleep by default; an explicit signal when declared (R6a added `"power"`, the power cycle, for a node with neither — §3.3) | works on every NM node with no config; ignition-driven ECUs name their input |
| D4 | Freeze-frame storage | chained records in the existing journal | built and fuzz-proven; resolves the `docs/nvm.md` contradiction |
| D5 | Security-access key | a board/OEM C seam; sim and bench use net's existing reference key | real keys are OEM secrets; the stack must not bake one in, and the tester must not need a second algorithm |
| D6 | First 0x19 subfunctions | 01, 02, 0A in R4; 03, 04, 06 with persistence in R6 | what a workshop reads first; snapshots need storage to mean anything |

## 6. Out of scope (said so that nobody assumes it)

A second diagnostic server on one node (a separate physical address on another bus — the per-server
epoch, suppression and response forwarding it needs are not designed); OBD / emissions services (0x01–0x0A modes, readiness monitors) and J1939 DM1 — declared separately if
an application needs them; ODX/PDX import (the manifest carries what the tester needs); 0x2F
InputOutputControl, 0x23/0x3D memory access, and generic 0x31 RoutineControl (the bootloader keeps
its own erase / check routines). DoIP is NOT a second server: `[doip]` on a ThreadX node carries
the one server over TCP as well (`tools/loom2v/gen_doip.v`) — the comm thread serves a DoIP request
from a mailbox (`driver/eth/doip_netx.c`) through `comm/diag`'s `serve_remote`, so a CAN and a DoIP
tester share one session — while a 0x27 unlock belongs to the transport that earned it, so a
network tester never writes under a bus tester's unlock (REQ-NET-012) — and a reset a DoIP tester asks for waits for its
answer to be acknowledged. Not built: a host-side DoIP transport, and the bootloader's DoIP binding.

## 7. Obligations carried into the rungs

Review of this plan kept finding real holes at the *mechanism* level — handshakes across threads,
crash windows between journal writes, edge-of-time cases. They are recorded here, each against the
rung that must meet it and the test that proves it, rather than solved in prose above: a rung is not
done until its obligations hold under their tests. §3 fixes the shape; this table is its checklist.

| Rung | Obligation | Proved by |
|---|---|---|
| R1 | Leaving a non-default session — explicitly, by S3, or by ECU reset — restores communication (0x28) to enabled. *Met in R1.* | unit + vcan: disable tx, return to default / let S3 expire / reset, frames resume |
| R2 | The programming handoff is offered only by a server whose bus and addresses the bootloader serves (today: CAN 0, 0x7B0 / 0x7B8 in the boot images), validated at generation; any other server refuses 0x10 02. | generation test on a mismatched config; bench: handoff reaches `boot.Prog` |
| R3 | A signal that never receives a good frame still reaches `timeout`: an initial reception deadline is armed at bridge start (and on NM wake), since today's monitor only runs after a first frame (`comm/com/com.v`). | host e2e: sender absent from boot → `timeout` after the grace period |
| R4 | A clear makes the prior generation obsolete: readings carrying a generation older than the one the clear requested are ignored until the producer acknowledges it, so an old-generation failure cannot recreate a cleared DTC. (Cycle transitions bump no generation — §3.3 as built in R4a.) | unit: clear with a failed producer that publishes once more before observing the control |
| R1 | One diagnostic server per node, enforced at generation: a second ISO-TP connection is refused outright (since the `[uds]` split, `[isotp]` is a table: there is no second one to write) (a bare one still exposes sessions, 0x28, reset), so the fault memory, the clear epoch, 0x85, NM keep-awake and the handoff each have exactly one owner. *(Replaces a multi-server design that review showed widening the surface round after round.)* | generation test: a second connection is refused |
| R4 | 0x85 DTC-setting-off is restored to on when the session ends (explicit, S3, reset), like 0x28. | unit + e2e: set off, disconnect, faults record again after S3 |
| R6 | Displacement is atomic across its two journal writes: the replacement is written first, and recovery resolves a temporary over-capacity set deterministically (lowest priority, then oldest, is the one dropped), so an interrupted displacement never loses both entries. | power-cut fuzz over the displacement sequence |
| R6 | A freeze frame never becomes a side door around DID access: a snapshot may only name DIDs readable in every session 0x19 is served in without security, or 0x19 04 applies the strictest gate of the DIDs it contains — decided in R6, enforced at generation. | generation test: a gated DID in `freeze` is rejected (or the gate applies) |
| R2 | A non-default diagnostic session holds NM awake (REQ-ECU-003): active sessions across the node's servers aggregate into a keep-awake request, released on return to default, S3 expiry and reset — diagnostic traffic is not an NM message and does not refresh NM on its own. | bench: extended session held across the NM timeout with application demand released |
| R2 | The programming handoff is gated on application safety conditions (REQ-BOOT-015) — declared condition signals (e.g. stationary, supply stable) evaluated before the boot cell is written; failing → 0x22. | host + bench: denied while moving / under-voltage |
| R2 | The session survives the handoff: `boot.Prog` starts in programming (not default) when the boot request cell caused its entry, so a tester that received 0x50 02 can proceed to 0x29 without a second 0x10 02. | bench: 0x10 02 → reset → 0x29 accepted |
| R3 | An E2E sequence gap (`lost`) is visible to the application, not only counted: a published loss counter (or a degraded status) (REQ-E2E-002). | host e2e: a single skipped counter reaches the FB |
| R4 | … and it is a fault source: `[[fault]] on = "lost"`. | host e2e: a single skipped counter raises its DTC |
| R4 | 0x85 suppression records nothing after the positive "off" and replays no suppressed occurrence after "on". *Met in R4a without a producer handshake:* suppression is applied where readings are consumed (§3.3); the accepted cost is that a qualification published before "off" but not yet read (≤ one owner pass) is not recorded. | unit: off, fail, on — nothing recorded, nothing replayed |
| R6 / R7 | Live state changes only after durability: a persisted 0x2E (parameters, `apply = "next_dispatch"`) and a persisted 0x14 stage their RAM change until the journal accepts the write; on refusal (0x72) both live and durable state are unchanged. | fault-injection tests asserting the current-run value, not only the stored one |
| R0 | Physical diagnostic ids are unique per BUS, not per system: REQ-TOPO-002 and `tools/sysmodel/checks.v` (which today put every allocation and ISO-TP connection id in one global map) are revised to key physical ids by bus and to allow a shared functional id. | syscheck tests: the same physical id on two separate buses passes; twice on one bus fails |
| R4 | The tested state is lossless like the occurrences: a monotonic tested-count per fault (not a last-value `tested` flag), so a fast producer's single evaluation followed by `.not_tested` is never lost to the test-not-completed bits or aging. | unit: one evaluation then `.not_tested`, read once late |
| R4 / R6 | Every list-producing 0x19 response fits the transport: generation bounds 0x19 02 / 0A (all DTCs × 4 B) and 03 (all snapshot ids) against the message limit with its header, and refuses a fault table that could exceed it. | generation test at the boundary |
| R6 | Snapshot and extended-data records carry stable on-wire record numbers — snapshot record 0x01 per DTC (one snapshot per fault), extended data 0x01 occurrence counter, 0x02 aging counter — with 0xFF (all) supported, and the numbering carried in the manifest for the tester. | unit: 0x19 03 / 04 / 06 with explicit and 0xFF record numbers; N3 decodes them |
| R0 | A functional id may be shared with OTHER functional ids on its bus, never with a physical request or response id there — checked in syscheck across the whole bus (loom2v checks the node's own ids). | syscheck test: a functional id equal to another node's physical id on the same bus fails |
| R6 | The clear epoch has a stable block identity like the entries (fixed / schema-derived, collision-handled, in the prune keep-set), so a firmware update can never prune it and resurrect cleared entries. | power-cycle test across a firmware update that reorders faults |
| R6 / R7 | Persistent writes never block the comm thread: `nvm.Journal.put` is synchronous (a full chain, or a compaction), so persisted 0x2E / 0x14 / fault-memory writes go through a bounded incremental flash path, with 0x78 covering the wait. | bench: CAN rx/tx, NM and 0x78 timing continue during a worst-case chain write and a compaction |
| R6 | Automatic fault-memory writes (qualification, cycle end) that the journal refuses are kept dirty and retried with bounded pacing — including in the sleep flush — rather than waiting for the next event, since no request is there to receive a 0x72. | fault-injection: a refused qualification write survives a later power cycle |
| R7 | Parameters get the entries' identity rules: a stable, schema-derived, collision-handled block id in the prune keep-set, so a firmware update that reorders or adds parameters never restores one parameter's bytes into another. | power-cycle across a reordering update |
| R7 | A restored parameter is revalidated against the CURRENT range before the FB first sees it; out of range → the compiled default (and a flag the tester can read), so a range narrowed by an update is never bypassed. | update test narrowing a range below a stored value |
| R6 | Signal-status faults (timeout / integrity / lost) raise their DTCs on silicon — moved here from R5, which proves only the FB-visible status. | bench: pull a sender → its DTC reads back over 0x19 |
| R2 | NM stays awake for a diagnostic exchange in ANY session: a request-scoped keep-awake vote from the first frame of a request until its final response has drained (diagnostic frames do not refresh NM), in addition to the session-scoped vote. | bench: a multi-frame 0x22 in the default session started near the NM timeout completes |
| R3 / R5 | An E2E-protected signal detects total sender loss inside the E2E mechanism itself (REQ-E2E-002): `e2e.RxState` gains its own deadline (`on_valid` / `expired`) and publishes the loss, independent of the QM COM deadline. | host (R3) and bench (R5): sender removed, loss seen with the COM deadline disabled |
| R6 | The operation-cycle END is a barrier too: before the sleep flush marks the journal clean, the fault memory waits for every producer to acknowledge the ending generation and persists what it read — power can be removed with no next cycle to drain the tail. | power-off right after bus sleep with a qualification in the last dispatch |
| R2 | 0x27's failed-key count survives a POWER CYCLE: persisted, with the boot lockout applied only while it is non-zero. R1b keeps it across an ECU reset (RAM) but not across a power-up, which a simulator need not defend. | bench: fail twice, power-cycle, the third wrong key locks out; a clean power-up unlocks at once |
| R6 | Persistent diagnostic counters have fixed serialized widths and SATURATE (occurrence, failed-cycle, aging); they never wrap to a small value. | unit: increment at the maximum |
