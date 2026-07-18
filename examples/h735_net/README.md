# h735_net — TCP/IP P1: link + ping (STM32H735G-DK)

The on-target TCP/IP bring-up milestone (docs/net.md, P1): **ThreadX + NetX Duo +
the register-level ETH driver**, doing nothing but bringing the LAN8742 link up and
pinging the gateway. A plain-C ThreadX app — no loom2v, no CAN, no config codegen —
so the only moving parts are the driver and the NetX glue this example exists to
prove on silicon.

**BENCH-VERIFIED on the H735-DK (2026-07-18):** 0% ping loss in both directions at
~1 ms RTT (direct board↔PC cable and via a switch). The bring-up found four real
bugs — see docs/net.md "P1 bring-up findings".

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

Set `IP_ADDR` / `GATEWAY` in `main.c` for your subnet first. See docs/net.md
"Bench bring-up checklist" for the debug order if link or ping doesn't come up.
