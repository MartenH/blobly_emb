# gw_srcverify — a translating gateway that VERIFIES the protected source frame

The counterpart to [gw_e2e](../gw_e2e): where gw_e2e re-protects the *destination*,
this **verifies the source**. `SrcFrame` (0x100) is E2E-protected; the route decodes
`Speed` **only when the source's E2E check passes**, then re-encodes it into an
unprotected `DstFrame` (0x200). A corrupt / replayed / tampered source frame is
rejected — its value never reaches the wire, and once the source goes stale the
destination is suppressed by the freshness deadline (dest-producer model,
`REQ-TOPO-008`).

```sh
sudo make vcan                     # bring up vcan0..vcan7
make -C examples/gw_srcverify      # gen + host build
./examples/gw_srcverify/bin/app vcan0 vcan1 &
# a SrcFrame with a valid E2E trailer (CRC byte6, counter byte7) forwards; a bad CRC does not
```

Test (`test/route_srcverify.lua`) constructs the E2E frames itself (SAE J1850 CRC-8,
the poly the gateway verifies with) and checks that a **valid** source is routed and a
**tampered** one (broken CRC) is never re-encoded onto the destination.

```sh
make -C examples/gw_srcverify test BLOBLY_NET=$HOME/repos/blobly_net
```

## Scope

A protected source frame is verified **once per frame** (each check advances the E2E
counter / SecOC freshness), so — for now — it may feed **exactly one route** and must
not also be read by a normal COM signal on the same bus; both cases are rejected at
generation (shared-verify for a fan-out source is a later increment).
