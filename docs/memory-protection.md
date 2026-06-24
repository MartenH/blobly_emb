# Memory protection design

Memory protection is **accounted for from day one** in the structure, even though
the host/sim build can't enforce it. The goal: when we add the ThreadX + MPU
target backend, turning protection *on* is a mechanical mapping from config, not
a redesign.

## The unit: a partition

A **partition** (≈ AUTOSAR OS-Application) is one MPU protection domain. It owns:
- its private RW data,
- its code/rodata (RX),
- a set of IOC channels it may read and/or write.

Partitions are declared in [`config/ecu.toml`](../config/ecu.toml) (`[[partition]]`)
and pinned to a core (AMP). A fault in an unprivileged partition stays local —
it cannot corrupt another partition or the kernel.

## Why the current code is already MPU-ready

Two deliberate choices, enforced now on host, make the retrofit trivial:

1. **Partition state lives on its core-thread's stack, never in shared globals.**
   See `IoPartition` / `AppPartition` in [`main.v`](../main.v): each is a local in
   `partition_io` / `partition_app`. On target, that becomes the partition's
   private MPU region. There is no ambient global state to leak across domains.

2. **Cross-partition data flows ONLY through IOC.** The IOC pool
   ([`osal/osal_native.c`](../osal/osal_native.c)) is the single shared region.
   Each channel is directional: the `from` partition gets RW, the `to` partition
   gets RO. The Loom-level lint already forbids the App partition from importing a
   driver, mirroring the MPU rule that it has no peripheral access.

## Target MPU region map (per core)

| Region | Perms | Who |
|--------|-------|-----|
| Partition private data | RW (priv or unpriv) | owning partition only |
| Code + rodata | RX | owning partition |
| IOC slot(s) — write side | RW | the `from` partition |
| IOC slot(s) — read side | RO | the `to` partition |
| CAN peripheral / MCAL | RW | **trusted** (IO) partition only |

`trusted = false` partitions (e.g. `app`) run unprivileged with no peripheral
region — application code physically cannot touch the bus.

## Roadmap to enforcement

1. ThreadX OSAL backend: map each partition onto a ThreadX module (MPU-isolated)
   or an MMU/MPU-guarded thread group, pinned to its core.
2. Generate the MPU region table above directly from `[[partition]]` + `[[ioc]]`.
3. IOC becomes a lock-free seqlock in a shared MPU region (the host shim already
   uses that algorithm), so no cross-domain locks are ever needed.
