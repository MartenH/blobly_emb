/* boards/h723/eth.h — NUCLEO-H723ZG Ethernet (ETH MAC/DMA + LAN8742A RMII PHY).
 *
 * The register-level half of the on-target TCP/IP driver (docs/net.md). NetX Duo's
 * nx_driver_stm32h7.c calls this; nothing here knows about NetX. Same DWC_ether_qos
 * MAC as the H735-DK (RM0468, H72x/H73x) — the MAC/DMA/MDIO/descriptor code is
 * identical; only the RMII pin map and the MDIO clock divider differ (this board's
 * HCLK is 200 MHz, see eth.c). All ETH signals are AF11.
 *
 * NUCLEO-144 (MB1364) RMII map — the ST default solder-bridge config.
 * BENCH VALIDATION PENDING: flash the eth image to ST-Link 0029003E3233510639363634
 * and ping 192.168.0.51 (the H735 sysnode/eth is .50). */
#ifndef BLOBLY_H723_ETH_H
#define BLOBLY_H723_ETH_H

#include <stdint.h>

/* --- NUCLEO-H723ZG RMII pinout (all AF11) —
 * REF_CLK PA1 | MDIO PA2 | MDC PC1 | CRS_DV PA7 | RXD0 PC4 | RXD1 PC5
 * TX_EN PG11 | TXD0 PG13 | TXD1 PB13 | LAN8742A MDIO address = 0.
 * (vs the H735-DK, which puts TX_EN/TXD0 on PB11/PB12 — this is the only pin delta.) */
#define ETH_PHY_ADDR 0u

/* Descriptor ring + buffer sizing — all static (no heap; REQ-NET-001/002). A
 * standard Ethernet MTU frame is 1522 bytes incl. CRC; round the buffer to a
 * cache-line-friendly 1536. The RX ring must absorb a broadcast burst between IP-
 * thread drains without dropping our own reply traffic. 16 RX + 4 TX buffers = 30 KB,
 * inside the 32 KB D2 SRAM the .eth_dma section lives in. */
#define ETH_RX_DESC_CNT 16u
#define ETH_TX_DESC_CNT 4u
#define ETH_BUF_SIZE    1536u

/* eth_init: clock + mux the RMII pins, bring up the MAC/DMA and the LAN8742
 * (soft-reset + auto-negotiation), install the descriptor rings. `mac` is the
 * 6-byte station address. Returns 0 on success, negative on a bring-up timeout. */
int eth_init(const uint8_t mac[6]);

/* eth_send: hand a single contiguous frame (len bytes) to a free TX descriptor and
 * kick the DMA. Returns 0 on success, -1 if no TX descriptor is free. */
int eth_send(const uint8_t *frame, uint32_t len);

/* eth_recv: pop one received frame into `buf` (>= ETH_BUF_SIZE), returning its
 * length, or 0 if no frame is ready. Called from the driver's deferred handler. */
uint32_t eth_recv(uint8_t *buf, uint32_t buf_size);

/* eth_link_up: read the LAN8742 status over MDIO; returns 1 if link is up. */
int eth_link_up(void);

/* eth_multicast_all: open the MAC RX filter to all multicast (MACPFR.PM); the
 * stack filters per-group in software. Idempotent. */
void eth_multicast_all(void);

/* eth_unique_mac: fill `mac` with a locally-administered address derived from the
 * STM32 96-bit unique ID — stable per chip, distinct across boards. */
void eth_unique_mac(uint8_t mac[6]);

/* eth_set_mac: reprogram the station-address filter only (no MAC/DMA/PHY reset). */
void eth_set_mac(const uint8_t mac[6]);

/* The ETH DMA RX interrupt plumbing. ETH_IRQHandler is the NVIC entry (vectors.S
 * IRQ61): it clears the DMA flag and calls the callback the driver installs with
 * eth_set_rx_callback (nx_driver_stm32h7.c points it at NetX deferred processing). */
void ETH_IRQHandler(void);
void eth_set_rx_callback(void (*cb)(void));

#endif /* BLOBLY_H723_ETH_H */
