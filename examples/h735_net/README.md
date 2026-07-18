# h735_net — TCP/IP P1: link + ping (STM32H735G-DK)

The on-target TCP/IP bring-up milestone (docs/net.md, P1): **ThreadX + NetX Duo +
the register-level ETH driver**, doing nothing but bringing the LAN8742 link up and
pinging the gateway. A plain-C ThreadX app — no loom2v, no CAN, no config codegen —
so the only moving parts are the driver and the NetX glue this example exists to
prove on silicon.

*** BENCH-UNVERIFIED on H735 *** — the code compiles + links; DMA/PHY/ISR timing is
verified on the DK. Same posture as `boards/h735dk/flash.c`.

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
