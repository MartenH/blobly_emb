# gw_compose — E2E + SecOC on one frame (REQ-E2E-004)

The destination frame carries **both** protections on disjoint bytes: `Speed` at
bytes 0–1, E2E CRC@2 + counter@3, SecOC freshness@4 + MAC@5–7. The generated
producer stamps E2E first (its CRC *excluding* the SecOC windows — `protect_ex`),
then SecOC over the E2E-protected result; a receiver verifies SecOC first and only
an authentic frame reaches the E2E check, so repeat/loss verdicts are never masked
by a passing MAC.

This example's job is to make CI **compile the composed generated bridge** on every
run — the naive composition was broken twice (an E2E CRC over bytes SecOC stamps
later; a generator that skipped the E2E check entirely when SecOC was present) and
nothing built the combination. The semantics themselves are pinned by
`comm/e2e/compose_test.v`.

Run it like the other gateways: `sudo make vcan`, `make`, `./bin/app vcan0 vcan1`.
