# Configuration

blobly_emb is configured from a **single `config/ecu.toml`** (TOML). Host
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
| `[bus.*]`, `[import] dbc` | communication | bus params; `dbc2cfg` → signal codec |
| `[[ioc]]` (+`transport`) | platform/comm | `gen.<name>_ch`, `gen.ioc_transport[]` |
| `[[component]]` / `[[component.handler]]` | application | (next) Loom wiring: instantiation + handler schedule |
| `[[signal]]` / `[[frame]]` | communication | hand-authored signals (or via DBC) |
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

Done: IOC channel ids + per-channel transport table, partition table. Next: the
**Loom wiring** codegen (component instantiation + handler registration with
periods/cores) from `[[component]]`, replacing the hand-written glue in `main.v`.
