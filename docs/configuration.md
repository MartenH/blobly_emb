# Configuration

> Looking for "how do I add a signal/frame/FB/core"? That's the task-oriented
> **user manual**: [docs/um/](um/README.md). This page is the design rationale.

blobly_emb is configured from a **single `ecu.toml` per example** (TOML). Host
build-time tools read it and **generate static, no-alloc V tables** — nothing
parses config on the target.

## Pipeline

```
config/ecu.toml ─┬─ tools/cfg2v   ─→ gen/ecu_gen.v        (channels, transport, partitions)
config/*.dbc   ──┴─ tools/dbc2cfg  ─→ comm/com/dbc_gen.v   (signal pack/unpack codec)
                    (heap OK, host)     (no-alloc, runtime)
```

Regenerate both with **`make gen`**. The generated files are committed (like any
codegen output) and must not be hand-edited — change `config/` or the generator.

## What's settled

- **TOML, single file.** One `ecu.toml` for the whole ECU; sections are
  namespaced per functional block so it can split later if it grows.
- **Build-time codegen, not runtime parsing.** Required by the no-alloc rule.
- **Comm matrix from DBC**, referenced via `[import] dbc = ...`.

## Sections (one per functional block)

| Section | Block | Generates / drives |
|---------|-------|--------------------|
| `[[partition]]` | platform | `gen.partition_cores/_trusted/_count`; core pinning + MPU domains |
| `[bus.*]` (+`core`,`fd`), `[import] dbc` | communication | bus params; bridge core; `dbc2cfg` → signal codec (decode+encode) |
| `[[signal]]` (+`from`/`to`/`fields`/`transport`) | comm/app | signal types (`sig`), ports, `gen.<name>_ch`, routing; bus endpoint → bridge rx/tx via `loom2v` |
| `[[frame]]` (`tx`/`rx`/`e2e`/`secoc`) | communication | per-PDU COM behaviour: tx mode/timing + rx deadline → `com.TxState`/`RxState`; `e2e` → `e2e.TxState`/`RxState` (CRC); `secoc` → `secoc.*` (AES-CMAC + freshness) |
| `[[isotp]]` (`rx_id`/`tx_id`/`bs`/`stmin_ms`) | communication | ISO-TP diagnostic connection → an `isotp.Link` in the bridge (reassemble/segment) |
| `[[did]]` (`ascii`/`bytes`/`signal`/`writable`) | diagnostics | UDS DataIdentifier → entry in the bridge's `uds.Server` (constant / live signal / RAM) |
| `[[route]]` (`from`/`to`) | communication | raw-PDU gateway: forward a frame bus→bus untouched (the source bridge sends on the destination channel) |
| `[[fb]]` / `[[fb.handler]]` | application | `gen.partition_*`: Loom wiring (state, handler glue, schedule) via `loom2v` |
| `[nm.*]` | network management | timings (placeholder until NM exists) |
| `[[nvm.block]]` | memory stack | NvM block layout (placeholder until NvM exists) |

`[nm]`/`[nvm]` sit as documented placeholders so the file grows with the stack
without restructuring.

## Consuming generated config

Runtime code imports `gen` and uses the typed constants instead of magic numbers:

```v
import gen
const ioc_speed = gen.vehicle_speed_ch   // not a hardcoded 0
```

## Status / next

Done: IOC channel ids + transport + partition tables (`cfg2v`); **Loom wiring**
(`loom2v` → `gen.partition_*`) — `main.v`'s app partition is now generated, so
adding a component is config-only. Each handler's glue uses the channel's
configured transport (e.g. `double` → `ioc_publish2`/`ioc_acquire2`).

Next: the IO/driver partition (bus rx/tx) from comm config, and the NM/NvM blocks
once those subsystems exist.
