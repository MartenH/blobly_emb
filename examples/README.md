# Examples

Each example is a **freestanding app** in its own folder. Build it from inside:

```sh
cd examples/overspeed
make all          # generate from config + compile -> bin/app
make run          # build + run on vcan0
```

…or from the repo root: `make example NAME=overspeed` (delegates to the above),
`make list` to list them.

## Integration testing (blobly_net + Lua)

An example can be driven and asserted on the bus by
[blobly_net](https://github.com/MartenH/blobly_net)'s **headless Lua runner** —
it knows the same DBC, so it encodes/sends stimulus signals and checks responses:

```sh
make vcan                                   # bring up vcan0 + vcan1
cd examples/overspeed
make test BLOBLY_NET=/path/to/blobly_net     # build + run the app + drive/assert
```

(Multi-bus examples like `gateway` use both `vcan0` and `vcan1`; `make vcan`
brings up both. Such an example opens each bus by its `[bus.*] interface` and
`main.v` calls `gen.run(c0, c1)` — one channel per bus.)

`make test` runs the built app on `vcan0` (the app *is* the ECU — the blobly_net
project has no simulation) and runs every `test/*.lua` against it; it exits
non-zero if any assertion fails. Each example provides `test/vcan.yml` (the
blobly_net project pointing at `vcan0` + `bus.dbc`) and `test/<name>.lua`, e.g.:

```lua
bus.send_message("CAN1", "Powertrain", { VehicleSpeed = 150 })  -- DBC-encode + send
-- ... then assert the lamp frame (0x101) goes ON
```

Note: blobly_net is classic-CAN, so these examples use classic CAN
(`[bus] fd = false`); the driver picks classic vs CAN-FD from that flag.

The only thing an example needs from the main repo is the path back to it
(`REPO`, default `../..`): the generators in `tools/`, and the shared framework
(`osal`/`loom`/`driver`) found via V's `-path`.

## Available

| Example | What it shows |
|---------|---------------|
| [`minimal`](minimal/) | one FB, **FB ↔ COM** only (bus in → SpeedMonitor → bus out) |
| [`overspeed`](overspeed/) | 4 FBs on 2 cores, **every** signal path (FB↔COM, same-core local cell, cross-core IOC) **+ diagnostics** (ISO-TP + UDS: per-PDU TX modes, RX deadline, DIDs incl. a live signal) |
| [`gateway`](gateway/) | **two CAN channels**: VehicleSpeed in on `can0` → SpeedMonitor → WarnLamp out on `can1`; plus a **raw-PDU `[[route]]`** forwarding `WheelSpeeds` `can0`→`can1` untouched |
| [`scale`](scale/) | **load benchmark** through the real stack: 4 cores, 8 CAN buses, **200 FBs** — config + FB handlers are themselves generated (`tools/scale_gen`). `make all`, then `make bench-scale` for per-core CPU + RAM. |

### On hardware (bare-metal targets)

These build with `arm-none-eabi-gcc` (`make -C ../.. deps` for CMSIS) and flash to a
real board — register-level drivers, no HAL, no RTOS. They transpile V `-freestanding`
and enter `main__main()` from a minimal `startup.c`.

| Example | Board | What it shows |
|---------|-------|---------------|
| [`h735_blinky`](h735_blinky/) | STM32H735G-DK | smallest bring-up: LED blink, ~1 KB, no heap |
| [`h735_canecho`](h735_canecho/) | STM32H735G-DK | **register-level FDCAN driver** on silicon: echo each frame with id+1 (M7 @ 550 MHz) |
| [`h735_app`](h735_app/) | STM32H735G-DK | **FBs + Loom + telemetry** on silicon: scheduled function blocks + per-core CPU load streamed as a CpuLoad frame (`0x7E0`), watchable live in blobly_net |
| [`h755_canfd`](h755_canfd/) | STM32H755 Nucleo | two-bus FDCAN echo (the driver made multi-device) |

## Layout — four clean buckets

```
examples/<name>/
  ecu.toml  bus.dbc     configuration   (the source of truth)
  app/   Function Blocks  hand-written (app)
  main.v entry: open CAN + gen.run   hand-written (platform, tiny)
  sig/   signal types     generated ┐ never edited
  ports/ In/Out structs   generated │  (sig from each [[signal]].fields;
  gen/   codec/tables/glue generated │   gen/loom_gen.v has the COM bus bridge)
         + COM bus bridge + run()    ┘
  Makefile               make all
```

Generated code never sits in a hand-written folder, and app never mixes with
platform. Imports are short (`import sig`, `import ports`, `import osal`) — V's
`-path` resolves the example's own modules and the shared framework.

## Adding an example

1. `cp -r examples/minimal examples/<name>` (then `rm -rf <name>/gen <name>/ports <name>/sig <name>/bin`).
2. Edit `ecu.toml` (each `[[signal]]` declares its `fields`, e.g.
   `fields = { kph = "u16", valid = "bool" }`), then write your `app/` FBs and `main.v`.
3. `cd examples/<name> && make all`.

Imports are not coupled to the example name, so copying needs no rewrites.
Routing is derived from each signal's `from`/`to`, where an endpoint is a
**partition** or a **bus**:

- an endpoint names a `[bus.*]` → **external**: the generated COM bridge
  rx-decodes / tx-encodes it via the DBC (the signal must be in the DBC);
- both endpoints are partitions → **internal**: `from == to` → local cell
  (same-partition FB→FB), else an IOC channel.

So "internal vs external" is explicit in config, not inferred.
