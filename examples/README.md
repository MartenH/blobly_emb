# Examples

Each example is a **self-contained app** in its own directory, with its own
`ecu.toml`. `make example NAME=<dir>` generates all of its code from config and
compiles it.

```sh
make list                      # list examples
make example NAME=overspeed     # generate + build examples/overspeed/app
make run-example NAME=minimal   # build + run on vcan0
```

## Available

| Example | What it shows |
|---------|---------------|
| [`minimal`](minimal/) | the basic case: one FB, **FB ↔ COM** only (bus in → SpeedMonitor → bus out) |
| [`overspeed`](overspeed/) | 4 FBs on 2 cores exercising **every** signal path: FB↔COM, same-core FB→FB (local cell), cross-core FB→FB (IOC) |

## Anatomy of an example

```
examples/<name>/
  ecu.toml        # the ECU config (partitions, signals, FBs, NM, ...)
  bus.dbc         # optional: CAN matrix imported by COM
  signals.v       # signal value types (hand-written)
  <fb>.v          # Function Blocks (hand-written): state + handlers
  main.v          # entry: the IO/bus-bridge partition + spawns
  gen_*.v         # GENERATED (make example): codec, channels, ports, Loom glue
  signal-map.md   # GENERATED: follow any signal end-to-end -> DBC
```

Everything in an example is one `module main`, so FBs reference signals and
generated symbols directly (no imports, no prefixes); only the shared framework
(`osal`, `loom`, `driver.can`) is imported. The runtime stays no-alloc; `main.v`
(the bus bridge) is the one place init-time heap/strings are allowed.

## Adding an example

1. `mkdir examples/<name>`; write `ecu.toml`, `signals.v`, your `<fb>.v` files,
   and a `main.v` (copy one as a starting point).
2. `make example NAME=<name>`.

Routing is derived from each signal's `from`/`to`: `from == to` → a local cell
(same-partition FB→FB), otherwise an IOC channel (with `transport`); an `io`
endpoint is bridged to the bus by COM.
