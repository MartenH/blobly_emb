# gw_e2e — a translating gateway that RE-PROTECTS the routed frame

The [gw_signal](../gw_signal) translating gateway, extended so the **destination**
frames carry end-to-end protection. A signal route decodes a value from an
**unprotected** source frame and re-encodes it into a destination frame; here the
destination frame's producer then **re-protects** that composed frame — a fresh
E2E CRC + counter, or a SecOC MAC + freshness — every cycle, exactly like a normal
COM producer. So a downstream receiver's E2E/SecOC check passes on the re-framed
value (`REQ-TOPO-008`, dest-producer model).

Two routes, one for each protection profile:

| route | source (can0, unprotected) | destination (can1, protected) |
|---|---|---|
| `Speed` | `SrcFrame` 0x100 | `DstFrame` 0x200 — **E2E** (data_id 0x2A, CRC@6, counter@7) |
| `Rpm`   | `SrcFrame2` 0x101 | `DstFrame2` 0x201 — **SecOC** (AES-CMAC, freshness@1, MAC@2..5) |

```sh
sudo make vcan                     # bring up vcan0..vcan7
make -C examples/gw_e2e            # gen + host build
./examples/gw_e2e/bin/app vcan0 vcan1 &
cansend vcan0 100#6400000000000000 # Speed 10.0 km/h -> DstFrame 0x200 (value + advancing E2E trailer)
candump vcan1                      # -> 200 [8] 00 0A 00 00 00 00 <crc> <ctr>
```

Test (`test/route_e2e.lua`) verifies **both** protections cryptographically: it
recomputes the E2E CRC (SAE J1850 CRC-8) and checks the counter advances by
exactly one, and it recomputes the SecOC MAC (a pure-Lua **AES-128-CMAC**,
RFC 4493, self-checked against a known vector) so the emitted MAC is proven to be
one a real receiver accepts — not merely nonzero/varying.

```sh
make -C examples/gw_e2e test BLOBLY_NET=$HOME/repos/blobly_net
```

## Scope

- **Destination re-protection** (this example): the route composes the dest frame
  and the producer stamps fresh protection. The source frame is **unprotected**.
- **A protected SOURCE frame is rejected** — the route decodes it raw, without
  verifying its protection, so routing one is a generation error until *source
  verify* (decode through the source frame's E2E/SecOC check) lands as a later
  increment.
