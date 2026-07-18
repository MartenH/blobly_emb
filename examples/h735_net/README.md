# h735_net — TCP/IP P1-P3a: link, ping, UDP, TCP (STM32H735G-DK)

The on-target TCP/IP bring-up milestones (docs/net.md): **ThreadX + NetX Duo + the
register-level ETH driver**. P1 brings the LAN8742 link up and pings the gateway;
P2 adds the UDP datagram service (REQ-NET-005) — an echo socket and a 1 Hz
telemetry broadcast. A plain-C ThreadX app — no loom2v, no CAN, no config codegen —
so the only moving parts are the driver and the NetX glue this example proves on
silicon.

**BENCH-VERIFIED on the H735-DK (2026-07-18):** P1 at 0% ping loss both directions
(~1 ms RTT); P2 UDP echo round-trips from a WSL host through the Windows NAT. The
bring-up found four real bugs — see docs/net.md "P1 bring-up findings".

## P2 bench checks

```sh
echo hi | nc -u -w2 192.168.0.50 5005   # UDP echo: prints "hi" back
echo hi | nc -w2 192.168.0.50 5007      # TCP echo: connect, echo, disconnect
nc -ul 5006                             # telemetry: one counters line per second
                                        #  (run on a host on the subnet; a WSL VM
                                        #   won't see the broadcast through NAT)
```

## Pieces

- `boards/h735dk/eth.c` / `eth.h` — register-level ETH MAC/DMA + LAN8742A RMII (RM0468).
- `net/nx_driver_stm32h7.c` — the NetX `NX_IP_DRIVER` driver contract.
- `main.c` — packet pool + IP + ICMP + a ping loop; outcome in `net_ping_ok` /
  `net_ping_fail` / `net_link_up` (read over SWD; no UART on the default DK wiring).

## Run

```sh
make -C ../.. deps    # once: ThreadX + NetX Duo + CMSIS headers
make flash            # st-flash the .bin, then halt + read net_ping_ok over SWD
```

Set `IP_ADDR` / `GATEWAY` in `main.c` for your subnet first. If link or ping
doesn't come up, see docs/net.md "P1 bring-up findings" — the debug order that
worked on the bench: RJ45 link LED (PHY alive?) → `net_link_up` over SWD
(autoneg?) → `eth_rx/tx_count` (frames moving?) → Wireshark on the peer.
