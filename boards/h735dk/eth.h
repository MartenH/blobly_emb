/* boards/h735dk/eth.h — STM32H735G-DK Ethernet (ETH MAC/DMA + LAN8742A RMII PHY).
 *
 * The register-level half of the on-target TCP/IP driver (docs/net.md). NetX Duo's
 * nx_driver_stm32h7.c calls this; nothing here knows about NetX. Pinout is the
 * CONFIRMED MB1520 map (stm32h7xx-hal reference + user); all ETH signals are AF11.
 *
 * Register sequences follow RM0468 (H72x/H73x) and the ST HAL; BENCH-VERIFIED on
 * the H735-DK 2026-07-18 (0% ping loss, ~1 ms RTT). */
#ifndef BLOBLY_H735DK_ETH_H
#define BLOBLY_H735DK_ETH_H

#include <stdint.h>

/* --- CONFIRMED RMII pinout (all AF11), bench-verified 2026-07-18 —
 * REF_CLK PA1 | MDIO PA2 | MDC PC1 | CRS_DV PA7 | RXD0 PC4 | RXD1 PC5
 * TX_EN PB11 | TXD0 PB12 | TXD1 PB13 | LAN8742A MDIO address = 0. */
#define ETH_PHY_ADDR 0u

/* Descriptor ring + buffer sizing — all static (no heap; REQ-NET-001/002). A
 * standard Ethernet MTU frame is 1522 bytes incl. CRC; round the buffer to a
 * cache-line-friendly 1536. The RX ring must absorb a broadcast burst between IP-
 * thread drains without dropping our own reply traffic — 4 was far too small (bench:
 * ~50% ICMP loss on a busy LAN). 16 RX + 4 TX buffers = 30 KB, inside the 32 KB
 * D2 SRAM the .eth_dma section lives in (TX needs few — one reply/ping in flight). */
#define ETH_RX_DESC_CNT 16u
#define ETH_TX_DESC_CNT 4u
#define ETH_BUF_SIZE    1536u

/* eth_init: clock + mux the RMII pins, bring up the MAC/DMA and the LAN8742
 * (soft-reset + auto-negotiation), install the descriptor rings. `mac` is the
 * 6-byte station address. Returns 0 on success, negative on a bring-up timeout. */
int eth_init(const uint8_t mac[6]);

/* eth_send: hand a single contiguous frame (len bytes) to a free TX descriptor and
 * kick the DMA. Returns 0 on success, -1 if no TX descriptor is free. (NetX packet
 * chains are linearised by the driver before calling this in P1.) */
int eth_send(const uint8_t *frame, uint32_t len);

/* eth_recv: pop one received frame into `buf` (>= ETH_BUF_SIZE), returning its
 * length, or 0 if no frame is ready. Called from the driver's deferred handler. */
uint32_t eth_recv(uint8_t *buf, uint32_t buf_size);

/* eth_link_up: read the LAN8742 status over MDIO; returns 1 if link is up. */
int eth_link_up(void);

/* The ETH DMA RX interrupt plumbing. ETH_IRQHandler is the NVIC entry (vectors.S
 * IRQ61): it clears the DMA flag and calls the callback the driver installs with
 * eth_set_rx_callback (nx_driver_stm32h7.c points it at NetX deferred processing). */
void ETH_IRQHandler(void);
void eth_set_rx_callback(void (*cb)(void));

#endif /* BLOBLY_H735DK_ETH_H */
