# COM modules — trace, NM, telemetry as routed clients

How platform capabilities (trace, network management, telemetry) attach to the
bus **without any of them being special**. The load-bearing idea: a frame id can
route to a **module**, not just a signal. Once that's true, trace is a row in the
routing table — the same as NM, the same as everything.

> This is the design that came out of stripping trace from the generator. Trace
> had grown to ~1000 lines smeared through 50% of `tools/loom2v/gen.v` because
> loom2v was **generating a control protocol** (TraceCmd/Rsp poll loop, ISO-TP
> dump, multi-core coordination) once per run-model. That protocol is really just
> **routing + a producer** — COM's job, done by hand. See
> [communication.md](communication.md), [nm.md](nm.md).

## The one generalisation: routes terminate at a signal *or* a module

Today `ecu.toml` routes `frame → signal → IOC cell`. We add `frame → module` as a
first-class routing destination: an inbound id can be delivered to a platform
module instead of decoded into a signal. Nothing about "trace" is special to the
router — it wires any module the same way.

But a module is not *one* id. Trace alone has five logical ports — `cmd` (rx),
`dump_fc` (rx), `rsp` (tx), `record` (tx), `stat` (tx) — and a bare
`0x712 → trace` route leaves two problems: the module would have to re-inspect
ids to tell `cmd` from `dump_fc` (the hand-tailoring back through the back door),
and the tx ids can't live in routes at all (a route is inherently bus→inward;
`rsp`/`record` are outbound). So the authored form is a **binding**, below; the
frame→module *routes* are generated from the rx bindings.

## Endpoint bindings: direction is declared, ids appear once

Each module's **endpoint schema** — its port names and their directions — is fixed
in the platform, part of the module itself:

| module | endpoint  | dir | meaning                                   |
|--------|-----------|-----|-------------------------------------------|
| trace  | `cmd`     | rx  | TraceCmd control frame → `on_cmd`         |
| trace  | `dump_fc` | rx  | ISO-TP flow control for the dump          |
| trace  | `rsp`     | tx  | command response                          |
| trace  | `record`  | tx  | raw records / dump stream                 |
| trace  | `stat`    | tx  | HandlerStat heartbeat                     |
| nm     | `pdu`     | rx+tx | NM hears and sends on the same id       |
| telem  | `cpuload` | tx  | CpuLoad                                   |
| telem  | `detail`  | tx  | LoadDetail                                |

`ecu.toml` **binds** each endpoint to a frame — a `bus.dbc` message name (the id
authority, same as signals) or a literal id — in the module's own block, so one
module's whole wire footprint sits in one place:

```toml
[trace]
bus     = "can0"
cmd     = "TraceCmd"   # rx: becomes a generated router entry
dump_fc = "TraceFc"    # rx
rsp     = "TraceRsp"   # tx: the module stamps outbound frames with this id
record  = 0x7E5        # tx: literal id (the raw stream isn't a decodable DBC message)

[nm]
bus = "can0"
pdu = 0x400            # rx+tx per the schema — COM knows the direction from the endpoint
```

The router loom2v generates is one match over **all** rx bindings — signals and
module endpoints alike — dispatching straight to the endpoint handler:

```v
for ch.recv(mut rx) {
    match rx.id {
        0x123 { /* signal Command -> its IOC cell */ }
        0x712 { tm.on_cmd(rx) }     // trace.cmd
        0x714 { tm.on_dump_fc(rx) } // trace.dump_fc
        0x400 { nm.on_pdu(rx) }     // nm.pdu
        else {}
    }
}
```

What this buys, point by point:

- **Ids appear once** — the binding. No `[[route]]` entry duplicating an id the
  module also has to know.
- **Direction is declared, not hand-tailored** — the schema says `cmd` is inbound
  and `rsp` is outbound; COM acts on the declaration, the generator emits nothing
  capability-specific.
- **The module never inspects ids** — the generated match calls `on_cmd`/`on_fc`
  directly (static dispatch, no-alloc, no interface table on target). The id → 
  endpoint mapping the old code hand-wove is now a config-driven table entry.
- **The "one routing table" survives as a generated artifact** — the manifest
  lists every id with its destination (signal or `module.endpoint`), so the
  at-a-glance view exists without the config duplicating itself.

*(Considered and rejected: endpoint-qualified routes — `[[route]] id=0x712
to="trace.cmd"` — work for rx but strand the tx ids in the module block anyway,
splitting one module's ids across two config shapes. And DBC-only naming, since
the raw record stream isn't a decodable message.)*

## What the endpoint schema looks like

The schema is **data owned by the platform module itself** — a `pub const` next
to the code that serves it, which loom2v (a V program) imports. No generator-side
table to drift from the module: the module *is* the table. One shared type
(`comm/com`, since COM owns routing):

```v
pub enum Dir {
    rx
    tx
    rxtx
}

pub struct Endpoint {
pub:
    name string
    dir  Dir
    doc  string
}
```

Each module declares its ports:

```v
// comm/trace/module.v
pub const endpoints = [
    com.Endpoint{name: 'cmd',     dir: .rx, doc: 'TraceCmd control'},
    com.Endpoint{name: 'dump_fc', dir: .rx, doc: 'ISO-TP flow control for the dump'},
    com.Endpoint{name: 'rsp',     dir: .tx, doc: 'command response'},
    com.Endpoint{name: 'record',  dir: .tx, doc: 'raw records / dump stream'},
    com.Endpoint{name: 'stat',    dir: .tx, doc: 'HandlerStat heartbeat'},
]

// comm/nm — same shape, nothing module-specific in the mechanism
pub const endpoints = [
    com.Endpoint{name: 'pdu', dir: .rxtx, doc: 'NM PDU (hears and sends on one id)'},
]
```

The rx convention is mechanical — endpoint `x` is served by method `on_x` — so
loom2v, importing the const:

- **validates** the `[trace]` block's keys against it (unknown endpoint or an
  unbound rx endpoint is a clear generation error listing the valid names),
- **emits** one match arm per bound rx endpoint (`0x714 { tm.on_dump_fc(rx) }`),
- **passes tx bindings into the constructor** (`trace.new_module(rsp_id: ...,
  record_id: ...)`) — tx endpoints are config the module stamps on its output;
  an `rxtx` endpoint simply gets both.

Runtime cost: zero — the const is generator input, the target never iterates it;
dispatch stays the generated static match. And drift is self-catching twice:
config↔schema drift fails generation, schema↔code drift (an endpoint without its
`on_<name>` method) fails to V-compile in the generated output.

## The COM-module interface (platform, written once)

Trace, NM and telemetry all implement the same tiny interface. The platform owns
it; loom2v never generates its body.

```v
interface ComModule {
    rx_ids() []u32                 // ids this module claims (drives the routing table)
    on_rx(f can.Frame)             // a routed frame arrived (trace: handle_cmd; NM: state machine)
    produce(mut out []can.Frame)   // hand COM whatever it wants to send this pass (tx_ready-gated)
}
```

- **`on_rx`** is the control plane. Trace: `trace.handle_cmd(mut ring, decode_cmd(f))`
  (already in `comm/trace`). NM: its message handler. It's just "a frame came in."
- **`produce`** is the data plane. Telemetry: CpuLoad every period. Trace: records
  from the hooks, or a **dump burst** once a dump command armed it (an on-demand
  producer — same category as telemetry's periodic one, different trigger). NM:
  its periodic messages.

## The generic comm loop (platform, capability-agnostic)

The comm thread — the thing loom2v used to hand-generate ~700 lines of, per
run-model — is now one loop that names no capability:

```
for {
    drain rx:  for each frame  ->  module = route[frame.id];  module.on_rx(frame)
    produce:   for each module ->  module.produce(mut out);   send out (tx_ready-gated)
    pace / sleep
}
```

Written once in the platform/comm. Host, ThreadX and bare-metal differ only in how
the loop is *hosted* (spawned thread vs comm thread vs inline superloop) and how it
reads the clock/channel — not in what it does.

## Trace = data from hooks + control by routing

Trace stops being a subsystem loom2v generates and becomes a `ComModule` plus three
**enter/exit hook families** that feed its ring — the recording model, unchanged and
already mostly present:

| event      | enter/exit source                              | record        |
|------------|------------------------------------------------|---------------|
| **ISR**    | Cortex-M / port exec-change hooks              | `new_isr`     |
| **thread** | RTOS (ThreadX exec hooks) / Loom on host       | `new_thread`  |
| **FB**     | Loom scheduler brackets each handler dispatch (`sched.set_trace_hook`, exists) | `new_fb` |

The hooks timestamp and push a `Record` into the ring. The trace module streams the
ring out via `produce` when a routed command arms it. `comm/trace` already has the
primitives: `handle_cmd`, `TraceBuffer`, `new_isr/new_thread/new_idle/new_fb`,
`status_rsp`. The **only** missing platform piece is the module wrapper + the generic
loop — neither of which is trace-specific.

## What loom2v generates (thin) vs what's platform (once)

**Platform library** (`comm/`, written + unit-tested once, no codegen):
- the generic comm loop (route + produce),
- `ComModule` and the concrete modules: `TraceModule`, `NmModule`, `TelemModule`,
- the trace owner logic (dump streaming, multi-core coordination) *inside* `TraceModule`.

**loom2v generates** (the same generation for every module):
- the **router match** from the rx bindings (id → signal | `module.endpoint`),
- entity-id / ring-size / scratch-cell **assignment**,
- **registration**: instantiate each configured module, hand it its config, add it
  to the comm thread's module list,
- **hook wiring**: FB enter/exit via the Loom scheduler (thread/ISR are port/RTOS).

That's it. `gen_trace.v` collapses from ~1000 lines of generated protocol to a
handful of lines of config — "trace is a module routed at `0x712`, 64-entry ring,
records on `0x7E5`." NM lands the same way with no new generator code.

## Why this is the fix, not another move

Every earlier attempt (extract emitters, a `Producer` interface, relocate to
`gen_trace.v`) moved the **generated owner-loop** around. The loop shouldn't be
generated at all — it's COM routing + a producer, and COM already owns routing.
Delete the generation; let the platform own the loop; make trace a routed client.
The strip (`gen.v` 3231 → 2192, trace fully removed, non-trace byte-identical) is
the enabling baseline; this doc is the re-add.
