# Examples

Each example is a **freestanding app** in its own folder. Build it from inside:

```sh
cd examples/overspeed
make all          # generate from config + compile -> bin/app
make run          # build + run on vcan0
```

…or from the repo root: `make example NAME=overspeed` (delegates to the above),
`make list` to list them.

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
