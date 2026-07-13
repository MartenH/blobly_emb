# How do I add another core?

One `ecu.toml` describes the whole node; a second core is a partition whose image the
generator emits elsewhere. Design: [../multi-image.md](../multi-image.md). Reference
pair: `examples/h755_threadx` (owner, CM7) + `examples/h755_m4_app` (satellite, CM4).

## 1. Declare the partition with `image =`

In the OWNER example's ecu.toml:

```toml
[[partition]]
name  = "m4"
core  = 1
image = "../h755_m4_app"       # emit this partition's image into that example dir

  [[partition.thread]]
  name     = "m4_app"
  priority = 11

[[fb]]
name   = "M4Load"
thread = "m4_app"

[[fb.handler]]
name      = "on_10ms"
period_ms = 10
writes    = ["M4Count"]

[[signal]]
name   = "M4Count"             # cross-core: from a satellite partition
fields = { n = "u32", acc = "u32" }
from   = "m4"
to     = "can0"
```

`make gen` in the owner dir now also writes the satellite's `sig/`, `ports/`,
`gen/loom_gen.v`, and `gen/loom_build.mk`, plus `gen/duo_gen.h` — the ONE cross-core
slot contract both images compile against. Cross-core signal rules are in
[add-a-signal.md](add-a-signal.md).

(`external = true` instead of `image =` declares a core whose image is hand-written —
identity only: manifest rows + handler ids, no generated code.)

## 2. The satellite example provides what every example provides

- **`main.v`** — a shim: `import gen` … `fn main() { gen.boot() }`.
- **`app/`** — its FBs, ports convention, exactly like any FB
  ([add-an-fb.md](add-an-fb.md)).
- **Glue C** (`m4_glue.c`) — the platform contract the generated code calls:
  `duo_wait_clocks` (park until the owner's clocks-ready flag), `board_timebase_init` /
  `board_now_us` (this core's DWT µs), `duo_ioc_init` + `duo_pub` (the xioc pool at the
  board's shared-SRAM map, `boards/<board>/duo.h`), `duo_trace_service` (the dump
  handoff), and an ISR stub for any vector the shared table names but this core never
  enables.
- **`Makefile`** — the right kernel port + flags for the core's architecture
  (`MCU_CM4`, ThreadX `ports/cortex_m4/gnu`, `TX_ENABLE_EXECUTION_CHANGE_NOTIFY`),
  `-I` the owner's `gen/` (for `duo_gen.h`), `boards/common/trace_hooks.c`, and a gen
  dependency on the owner:

  ```make
  gen/loom_gen.v:
  	$(MAKE) -C ../h755_threadx gen
  -include gen/loom_build.mk
  ```

The boards layer owns everything silicon-specific: memory maps/linker scripts per core,
the shared-SRAM `duo.h` map, boot handshake conventions. Nothing about the core's KIND
leaks into ecu.toml — a third core is another `[[partition]]` block.

## 3. Boot, flash, verify

The owner core owns clocks/pins/bus and releases the satellite via the clocks-ready
flag; the satellite runs from its own flash bank (H755: CM7 bank 1 @ 0x08000000, CM4
bank 2 @ 0x08100000, both auto-booted by option bytes).

```sh
(cd ../h755_m4_app  && make && st-flash write build/h755_m4_app.bin 0x08100000)
(cd ../h755_threadx && make && st-flash write build/h755_threadx.bin 0x08000000 && st-flash reset)
candump can0            # the satellite's frame appears, payload advancing at its FB rate
```

What you get for free on the new core: its own trace recorder (per-core ring, own
timebase) dumped through the owner as extra self-describing blocks — the GUI swimlane
grows a lane set for the core with named threads/handlers
([record-a-trace.md](record-a-trace.md)); per-handler ids in the shared manifest; xioc
health checkable from the owner's shell (the `iocx` pattern).
