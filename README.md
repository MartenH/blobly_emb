# blobly_emb

An embedded **automotive stack written in [V](https://vlang.io)** — multicore-ready,
sim-first, and built to run **without dynamic memory allocation**.

It's a lean alternative to AUTOSAR Classic: you write application **components**
with typed ports and periodic **handlers**, and the **Loom** wires them to bus
signals and dispatches them on a schedule. No AUTOSAR vocabulary, no `malloc`.

## Layers

```
app/      Components: typed ports + periodic handlers  <- what developers write
loom/     The Loom: wiring + dispatch (generated from config)
comm/     The comms stack you own: com (signals) -> pdur -> cantp -> canif
driver/   Driver port: can (sim=SocketCAN, target=MCAL)
osal/     OS Abstraction Layer: time/tasks (sim=POSIX, target=ThreadX SMP)
config/   ecu.toml — signals, frames, schedule (source for Loom codegen)
```

Only `osal/` and `driver/` have two backends; everything above is portable V.

## First slice

`SpeedMonitor` reads `SpeedFrame (0x100)` on `vcan0`, and raises `LampFrame
(0x101)` when speed > 120 km/h — exercising every layer end to end.

```sh
make vcan      # bring up vcan0 (needs sudo)
make run       # build + run the stack
# in another shell:
candump vcan0                     # watch
cansend vcan0 100##0.7B00         # kph=0x007B=123  -> lamp on (101#01)
cansend vcan0 100##0.0000         # kph=0          -> lamp off (101#00)
```

## House style: no dynamic allocation

`app/` and `comm/` use only fixed arrays (`[N]u8`), value structs, and static
tables — never `string`, `map`, or growable `[]T`. Enforced in CI:

```sh
make lint
```

## Status

Research / learning stage. Decisions so far: V + C backend, sim-first on host,
ThreadX (SMP) as the target OS behind the OSAL, CAN/CAN-FD as the first bus.
Roadmap: Loom codegen from `ecu.toml` → ISO-TP → UDS → multicore (AMP) → ThreadX
target backend.
