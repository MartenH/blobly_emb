# Modules & requirement areas

The decomposition the requirements are organised around. A **module** is an
implementation grouping; a **requirement area** is a capability. They are mostly
1:1, but one module may cover several areas (the Conductor implements ECU + INIT
+ MODE), because requirements are capability-based and implementation-agnostic.

Requirements live in `requirements/<area>.toml`. `make trace` derives the area
from each ID prefix (`REQ-<AREA>-NNN` / `SYS-REQ-<AREA>-NNN`).

## The modules

| Module | Purpose | Area(s) | Reqs |
|---|---|---|---|
| **osal** | platform line: cores, time, init primitives | OSAL | planned |
| **ioc** | lock-free cross-core signal transport | IOC | planned |
| **can** | CAN/CAN-FD driver port + backends (socket / fdcan / hal / canif) | CAN-DRV | ✅ |
| **loom** | static scheduler — snapshot In, run handlers, publish Out | SCHED | planned |
| **app** | Function Block model + the application contract | APP | planned |
| **com** | signal ⇄ PDU, TX modes, RX deadline monitoring | COM | planned |
| **route** | raw-PDU routing / gateway | ROUTE | planned |
| **tp** | ISO-TP segmented transport (15765-2) | TP | planned |
| **diag** | UDS diagnostic services (14229) | DIAG | planned |
| **e2e** | end-to-end protection (safety: CRC + alive counter) | E2E | planned |
| **secoc** | authenticated messaging (security: CMAC + freshness) | SEC | planned |
| **nm** | network management — coordinated wake/sleep | NM | ✅ |
| **ecu** (Conductor) | ECU lifecycle states + deterministic init order + mode arbitration | ECU, INIT, MODE | ✅ |
| **wdg** (Sentinel) | alive + deadline supervision, services the HW watchdog | WDG | ✅ |
| **nvm** | non-volatile storage of calibration / state | MEM | future |

Cross-cutting (not a module — properties of the whole):

| Area | What | Method |
|---|---|---|
| **SYS** | system / safety / non-functional requirements (top tier) | mixed |
| **INV** | runtime invariants — no-alloc, SPSC, partition isolation, naming | analysis / review |

## Layering

```
            app (Function Blocks)
                  │  ports
        loom (scheduler)  ── ecu (Conductor: lifecycle/init/modes)
                  │                 │              │
   ioc ◄──────────┘                 │            wdg (Sentinel)
                                    │
   com ─ route ─ tp ─ diag ─ e2e ─ secoc ─ nm     (communication)
                  │
        can (driver port + backends)
                  │
              osal (cores / time / platform)
```

The **Conductor** sits beside the Loom and drives bring-up + modes; the
**Sentinel** supervises everyone; **NM** feeds the Conductor each network's
sleep-readiness. Everything below `com` is the comms stack over the `can` driver,
on the `osal`/`ioc` platform line.

## Authored so far

`system`, `ecu` (ECU/INIT/MODE), `nm`, `wdg`, `can-drv`, `inv`. The remaining
existing modules (`com`, `ioc`, `tp`, `diag`, `e2e`, `secoc`, `loom`, `app`,
`osal`) get baselined from what's already built + tested; `nvm` is future.
