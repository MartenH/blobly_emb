# TCP as configuration — a design note (decision pending)

**Question:** an eth node wants "normal" TCP/IP — a raw TCP service (a custom protocol, a
telemetry stream, a diagnostic channel) declared in `ecu.toml`, not hand-wired. Is that a new
generator seam, and is it worth building? This note scopes it so we can decide. Nothing here is
built yet; it is the map, not the spec.

## What already exists (so we don't over-estimate)

TCP itself is **not missing** — it is proven on silicon:

- `examples/h735_net` runs a working NetX **TCP echo server** (`nx_tcp_socket_create` / `listen`
  / `accept` / `receive` / `send`), bench-verified alongside UDP + ICMP.
- `comm/doip` runs a real protocol **over TCP 13400** (ISO 13400): `examples/h735_doip/netx_glue.c`
  owns the sockets and NetX bring-up; the V module does the framing and UDS.

And the **seam** that a config-driven version would generalize already exists, cleanly split:

> The C glue **owns the sockets** (NetX bring-up + the accept/receive/send loop). It hands the V
> module **raw TCP bytes** and takes back **response bytes** — no protocol logic in C. DoIP's
> contract is `Server.feed(data, len, resp, resp_max) int` (`comm/doip/doip.v`): "consume one chunk
> of TCP bytes, emit every complete message's response." The glue's own header calls it the
> **four-call byte-pipe seam**.

So the protocol logic is already config/V, and the transport is already a shared NetX backend
(`driver/eth/eth_netx.c`, `net/nx_driver_stm32h7.c`). What is **hand-written per example** is the
*socket ownership* — the `accept`/`receive`/`send` loop, the packet-pool sizing, the connection
lifecycle (idle timeout, disconnect, relisten). That loop is what "TCP-as-config" would generate.

## What "TCP-as-config" would add

A declaration in `ecu.toml`, e.g.

```toml
[[tcp_service]]
name    = "diag"        # names the ComModule that rides the byte-pipe
port    = 13400
role    = "server"      # server (listen/accept) | client (connect)
window  = 2048
max_len = 1568          # framing bound → packet-pool sizing
```

from which **loom2v generates** the socket loop and wires it to a named **ComModule** (the same
idea as trace / NM / telem — see `docs/com-modules.md`): the generated loop calls the module's
`feed(bytes) -> resp` on each chunk and sends the response. The module (`comm/<name>`) is
plain V, unit-testable off-target against a byte-oracle, exactly like `comm/doip` is today.

**Boundary that stays board glue (not config, by design):** NetX bring-up — the packet pool, the
IP thread, ARP/ICMP, the ETH driver, the board's PHY/MAC — lives in `boards/<board>/eth.c` +
`netx_glue`. That is per-board BSP; it will never be TOML, and that is correct (every board needs
a BSP). TCP-as-config only removes the *per-service* socket loop, not the *per-board* bring-up.

## The design questions to settle before building

1. **Server vs client.** DoIP/echo are servers (listen). A client (connect-out, e.g. pushing
   telemetry to a collector) needs reconnect/backoff policy. Start with server-only?
2. **Framing.** TCP is a byte stream; the module must self-frame (DoIP assembles by its length
   header). The generated loop stays framing-agnostic — it hands chunks, the module reassembles.
   `max_len` bounds the packet pool, not the message.
3. **Thread & memory.** One `svc` thread per service, or share the eth comm thread? Each socket
   costs a static packet pool + window; sizing is `max_len`-driven and must be static (REQ-NET-001,
   no heap). Multiple connections (a pool of sockets) is a v2 question — start single-connection.
4. **Composition.** A node running SOME/IP-over-UDP *and* a `[[tcp_service]]` shares one IP
   instance; the generator must add TCP sockets to the existing NetX bring-up, not a second stack.
5. **Contract shape.** Reuse DoIP's `feed(data,len,resp,resp_max) int` as the standard ComModule
   byte-pipe contract, so every TCP module is the same testable shape.

## Recommendation

**Build it, but pull it by a real consumer — not speculatively.** The seam is proven and the
generalization is bounded (a generated socket loop + ComModule wiring; the hard parts — NetX,
static memory, framing — are already solved and stay where they are). The right trigger is the
**eth-only H723 node**: give it SOME/IP-over-UDP (pure config today) *plus* one `[[tcp_service]]`
so the generator seam lands with an on-silicon consumer that exercises it, instead of a paper
feature. Until then, a one-off TCP service stays hand-glued (copy `h735_net`'s ~40-line loop) —
which is the honest DRY threshold: generalize on the **second** hand-written TCP loop, not the first.

Model it as a ComModule (`docs/com-modules.md`), keep the module contract identical to DoIP's
`feed`, and the H723-eth node becomes board glue (`eth.c`) + config — the same shape as every
other node.
