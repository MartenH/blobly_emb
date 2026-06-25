# Examples

Each example is a **freestanding app** in its own folder. Build it from inside:

```sh
cd examples/overspeed
make all          # generate from config + compile -> bin/app
make run          # build + run on vcan0
```

…or from the repo root: `make example NAME=overspeed` (delegates to the above),
`make list` to list them.

## Integration testing (cantester_v + Lua)

An example can be driven and asserted on the bus by
[cantester_v](https://github.com/MartenH/cantester_v)'s **headless Lua runner** —
it knows the same DBC, so it encodes/sends stimulus signals and checks responses:

```sh
make vcan                                   # bring up vcan0
cd examples/overspeed
make test CANTESTER=/path/to/cantester_v     # build + run the app + drive/assert
```

`make test` runs the built app on `vcan0` (the app *is* the ECU — the cantester
project has no simulation) and runs every `test/*.lua` against it; it exits
non-zero if any assertion fails. Each example provides `test/vcan.yml` (the
cantester project pointing at `vcan0` + `bus.dbc`) and `test/<name>.lua`, e.g.:

```lua
bus.send_message("CAN1", "Powertrain", { VehicleSpeed = 150 })  -- DBC-encode + send
-- ... then assert the lamp frame (0x101) goes ON
```

Note: cantester is classic-CAN, so these examples use classic CAN
(`[bus] fd = false`); the driver picks classic vs CAN-FD from that flag.

The only thing an example needs from the main repo is the path back to it
(`REPO`, default `../..`): the generators in `tools/`, and the shared framework
(`osal`/`loom`/`driver`) found via V's `-path`.

## Available

| Example | What it shows |
|---------|---------------|
| [`minimal`](minimal/) | one FB, **FB ↔ COM** only (bus in → SpeedMonitor → bus out) |
| [`overspeed`](overspeed/) | 4 FBs on 2 cores, **every** signal path: FB↔COM, same-core FB→FB (local cell), cross-core FB→FB (IOC) |

## Layout — four clean buckets

```
examples/<name>/
  ecu.toml  bus.dbc     configuration   (the source of truth)
  sig/   signal types    app  ┐ hand-written
  app/   Function Blocks  app  ┘
  main.v IO/bus bridge    platform (hand-written)
  ports/ In/Out structs   generated ┐ never edited
  gen/   codec/tables/glue generated ┘
  Makefile               make all
```

Generated code never sits in a hand-written folder, and app never mixes with
platform. Imports are short (`import sig`, `import ports`, `import osal`) — V's
`-path` resolves the example's own modules and the shared framework.

## Adding an example

1. `cp -r examples/minimal examples/<name>` (then `rm -rf <name>/gen <name>/ports <name>/bin`).
2. Edit `ecu.toml`, `sig/`, `app/`, `main.v`.
3. `cd examples/<name> && make all`.

Imports are not coupled to the example name, so copying needs no rewrites.
Routing is derived from each signal's `from`/`to`: `from == to` → local cell
(same-partition FB→FB), else an IOC channel; an `io` endpoint is bridged to the
bus by COM.
