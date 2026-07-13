# How do I add a thread or partition?

## Threads

A thread is a `[[partition.thread]]` entry. Each one gets its own ThreadX thread, Loom
scheduler, 4 KB stack, TCB, load slot, and trace lane — all generated.

```toml
[[partition]]
name    = "app"
core    = 0                    # REQUIRED (omitting would silently pin to core 0)
trusted = true

  [[partition.thread]]
  name     = "load_fast"       # globally unique — FBs bind by this name
  priority = 11                # ThreadX: LOWER number = HIGHER priority

  [[partition.thread]]
  name     = "ctrl_slow"
  priority = 13
```

- **At most 4 threads per partition** (static TCB/stack/scheduler per thread).
- Priorities are rate-monotonic by convention: fastest handlers on the
  highest-priority (lowest-number) thread.
- The **comm thread is implicit** — the bus owner gets one at `min(app priorities) - 1`
  so rx never starves ([../platform docs](../architecture.md)). Don't declare it.
- Assign FBs with `[[fb]] thread = "load_fast"`. Moving an FB between threads is a
  one-line config change; `make gen` re-derives schedules, stacks, manifest, stats.

## Partitions

A partition groups threads on a core (and is the future MPU isolation domain). Most
nodes have one local partition; the `[target]` build requires **exactly one partition
that is local** (not `external`/`image`) — additional partitions are other cores'
images, see [add-a-core.md](add-a-core.md).

## After editing

```sh
make gen && git diff gen/
```

Check the diff: new `g_<thread>_tcb/stack/sched` globals, a `run_<thread>()` loop, the
`tx_application_define` creation order (which is also the deterministic trace thread-id
order), and updated manifest `thread,` rows. Then `make && make flash`, and `ps` over
the shell shows the new thread with its stack high-water.
