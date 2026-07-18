/* boards/h735dk/eth.c — STM32H735 Ethernet MAC/DMA + LAN8742A RMII driver.
 *
 * The register-level hardware half of the on-target TCP/IP stack (docs/net.md).
 * Register sequences follow RM0468 (H72x/H73x, the DWC_ether_qos MAC) and the ST
 * HAL bring-up order. D-cache is OFF on this board (docs/no-alloc.md), so DMA
 * descriptors/buffers need NO clean+invalidate — a real simplification here.
 *
 * *** DRY-CODED, BENCH-UNVERIFIED on H735 *** (same posture as flash.c): the
 * H735-DK bench is where the ISR/DMA/PHY timing gets silicon-verified. Pinout is
 * the CONFIRMED MB1520 map (docs/net.md); all ETH signals are AF11.
 *
 * Descriptor format: the H7 "normal" 4-word descriptor (RDES/TDES 0..3). One
 * buffer per descriptor, single-frame (no chaining) for the P1 link+ping cut. */
#include "eth.h"
#include <stm32h735xx.h>
#include <string.h>

/* --- descriptor + buffer memory (static; no heap). 32-byte aligned so a ring
 * base lands cleanly even though D-cache is off. Placed by the linker in normal
 * SRAM reachable by the ETH DMA (D2 SRAM on H7; the .ld puts .eth_dma there). */
typedef struct {
	volatile uint32_t des0, des1, des2, des3;
} eth_desc_t;

static eth_desc_t rx_desc[ETH_RX_DESC_CNT] __attribute__((aligned(32), section(".eth_dma")));
static eth_desc_t tx_desc[ETH_TX_DESC_CNT] __attribute__((aligned(32), section(".eth_dma")));
static uint8_t rx_buf[ETH_RX_DESC_CNT][ETH_BUF_SIZE] __attribute__((aligned(32), section(".eth_dma")));
static uint8_t tx_buf[ETH_TX_DESC_CNT][ETH_BUF_SIZE] __attribute__((aligned(32), section(".eth_dma")));

static uint32_t rx_idx; /* next RX descriptor the CPU will inspect */
static uint32_t tx_idx; /* next TX descriptor the CPU will fill */
static void (*rx_cb)(void);

/* --- RDES3 / TDES3 bit fields (RM0468) --- */
#define DESC_OWN (1u << 31) /* owned by DMA */
#define RDES3_IOC (1u << 30)
#define RDES3_BUF1V (1u << 24)
#define RDES3_LD (1u << 28)             /* last descriptor of a frame */
#define RDES3_FD (1u << 29)             /* first descriptor of a frame */
#define RDES3_PL_MASK (0x00007FFFu)     /* packet length (bytes) after write-back */
#define TDES2_IOC (1u << 31)
#define TDES2_B1L_MASK (0x00003FFFu)    /* buffer-1 length */
#define TDES3_FD (1u << 29)
#define TDES3_LD (1u << 28)
#define TDES3_CIC_IPHDR_PL (3u << 16)   /* checksum insertion: IP header + payload */

/* ------------------------------------------------------------------ MDIO ---- */
/* The MAC's MDIO clause-22 access (MACMDIOAR/MACMDIODR). CR = clock-range divider
 * for the MDC (must yield 1..2.5 MHz from the AHB/HCLK ~275 MHz -> DIV124). */
static int mdio_wait(void) {
	for (uint32_t t = 0; (ETH->MACMDIOAR & ETH_MACMDIOAR_MB) != 0u; t++) {
		if (t > 200000u) {
			return -1;
		}
	}
	return 0;
}

static int phy_read(uint32_t reg, uint16_t *val) {
	uint32_t ar = (ETH_PHY_ADDR << ETH_MACMDIOAR_PA_Pos)
	            | ((reg & 0x1Fu) << ETH_MACMDIOAR_RDA_Pos)
	            | (4u << ETH_MACMDIOAR_CR_Pos) /* DIV124 */
	            | (3u << ETH_MACMDIOAR_MOC_Pos) /* 11 = read */
	            | ETH_MACMDIOAR_MB;
	ETH->MACMDIOAR = ar;
	if (mdio_wait() != 0) {
		return -1;
	}
	*val = (uint16_t)ETH->MACMDIODR;
	return 0;
}

static int phy_write(uint32_t reg, uint16_t val) {
	ETH->MACMDIODR = val;
	uint32_t ar = (ETH_PHY_ADDR << ETH_MACMDIOAR_PA_Pos)
	            | ((reg & 0x1Fu) << ETH_MACMDIOAR_RDA_Pos)
	            | (4u << ETH_MACMDIOAR_CR_Pos)
	            | (1u << ETH_MACMDIOAR_MOC_Pos) /* 01 = write */
	            | ETH_MACMDIOAR_MB;
	ETH->MACMDIOAR = ar;
	return mdio_wait();
}

/* LAN8742 registers: BCR(0), BSR(1). BCR bit15 = soft reset, bit12 = AN enable,
 * bit9 = AN restart. BSR bit2 = link up, bit5 = AN complete. */
static int phy_bringup(void) {
	if (phy_write(0u, 0x8000u) != 0) { /* soft reset */
		return -1;
	}
	uint16_t bcr;
	for (uint32_t t = 0;; t++) { /* reset self-clears */
		if (phy_read(0u, &bcr) != 0) {
			return -1;
		}
		if ((bcr & 0x8000u) == 0u) {
			break;
		}
		if (t > 200000u) {
			return -1;
		}
	}
	if (phy_write(0u, 0x1200u) != 0) { /* AN enable + restart */
		return -1;
	}
	return 0;
}

int eth_link_up(void) {
	uint16_t bsr;
	if (phy_read(1u, &bsr) != 0) {
		return 0;
	}
	return (bsr & 0x0004u) ? 1 : 0;
}

/* ---------------------------------------------------------- pins + clocks --- */
/* mux one pin to AF11, very-high speed. `af_hi` selects AFR[1] (pins 8..15). */
static void mux_af11(GPIO_TypeDef *port, uint32_t pin) {
	port->MODER = (port->MODER & ~(3u << (pin * 2u))) | (2u << (pin * 2u));
	port->OSPEEDR |= (3u << (pin * 2u));
	uint32_t idx = pin >> 3;             /* AFR[0] pins 0..7, AFR[1] pins 8..15 */
	uint32_t sh = (pin & 7u) * 4u;
	port->AFR[idx] = (port->AFR[idx] & ~(0xFu << sh)) | (11u << sh);
}

static void eth_pins_init(void) {
	RCC->AHB4ENR |= RCC_AHB4ENR_GPIOAEN | RCC_AHB4ENR_GPIOBEN | RCC_AHB4ENR_GPIOCEN;
	(void)RCC->AHB4ENR;
	/* PA1 REF_CLK, PA2 MDIO, PA7 CRS_DV */
	mux_af11(GPIOA, 1u);
	mux_af11(GPIOA, 2u);
	mux_af11(GPIOA, 7u);
	/* PB11 TX_EN, PB12 TXD0, PB13 TXD1 */
	mux_af11(GPIOB, 11u);
	mux_af11(GPIOB, 12u);
	mux_af11(GPIOB, 13u);
	/* PC1 MDC, PC4 RXD0, PC5 RXD1 */
	mux_af11(GPIOC, 1u);
	mux_af11(GPIOC, 4u);
	mux_af11(GPIOC, 5u);
}

/* --------------------------------------------------------- descriptor rings - */
static void rings_init(void) {
	rx_idx = 0;
	tx_idx = 0;
	for (uint32_t i = 0; i < ETH_RX_DESC_CNT; i++) {
		rx_desc[i].des0 = (uint32_t)(uintptr_t)&rx_buf[i][0];
		rx_desc[i].des1 = 0;
		rx_desc[i].des2 = 0;
		rx_desc[i].des3 = DESC_OWN | RDES3_IOC | RDES3_BUF1V; /* give to DMA */
	}
	for (uint32_t i = 0; i < ETH_TX_DESC_CNT; i++) {
		tx_desc[i].des0 = (uint32_t)(uintptr_t)&tx_buf[i][0];
		tx_desc[i].des1 = 0;
		tx_desc[i].des2 = 0;
		tx_desc[i].des3 = 0; /* owned by CPU until a frame is queued */
	}
	/* point the DMA channel at the rings (base, length-1, tail). */
	ETH->DMACRDLAR = (uint32_t)(uintptr_t)&rx_desc[0];
	ETH->DMACRDRLR = ETH_RX_DESC_CNT - 1u;
	ETH->DMACRDTPR = (uint32_t)(uintptr_t)&rx_desc[ETH_RX_DESC_CNT - 1u];
	ETH->DMACTDLAR = (uint32_t)(uintptr_t)&tx_desc[0];
	ETH->DMACTDRLR = ETH_TX_DESC_CNT - 1u;
	ETH->DMACTDTPR = (uint32_t)(uintptr_t)&tx_desc[0];
}

/* ---------------------------------------------------------------- init ------ */
int eth_init(const uint8_t mac[6]) {
	/* 1. clocks: SYSCFG (for RMII select) + the three ETH clocks + GPIO, and the
	 * D2 AHB SRAM the descriptor rings live in (.eth_dma at 0x30000000 — the ETH
	 * DMA is an AHB master and cannot reach the DTCM the rest of RAM sits in). */
	RCC->AHB2ENR |= RCC_AHB2ENR_SRAM1EN | RCC_AHB2ENR_SRAM2EN;
	RCC->APB4ENR |= RCC_APB4ENR_SYSCFGEN;
	(void)RCC->APB4ENR;
	/* RMII interface select: SYSCFG_PMCR EPIS[2:0] = 100. */
	SYSCFG->PMCR = (SYSCFG->PMCR & ~SYSCFG_PMCR_EPIS_SEL_Msk) | (4u << SYSCFG_PMCR_EPIS_SEL_Pos);
	RCC->AHB1ENR |= RCC_AHB1ENR_ETH1MACEN | RCC_AHB1ENR_ETH1TXEN | RCC_AHB1ENR_ETH1RXEN;
	(void)RCC->AHB1ENR;
	eth_pins_init();

	/* 2. DMA software reset (DMAMR.SWR self-clears when done). */
	ETH->DMAMR |= ETH_DMAMR_SWR;
	for (uint32_t t = 0; (ETH->DMAMR & ETH_DMAMR_SWR) != 0u; t++) {
		if (t > 1000000u) {
			return -1;
		}
	}

	/* 3. MAC: station address, then bring up the PHY over MDIO. */
	ETH->MACA0HR = ((uint32_t)mac[5] << 8) | (uint32_t)mac[4];
	ETH->MACA0LR = ((uint32_t)mac[3] << 24) | ((uint32_t)mac[2] << 16)
	             | ((uint32_t)mac[1] << 8) | (uint32_t)mac[0];
	if (phy_bringup() != 0) {
		return -2;
	}

	/* 4. DMA bus mode + per-channel control; TX/RX store-and-forward in the MTL. */
	ETH->DMASBMR |= ETH_DMASBMR_AAL;   /* address-aligned beats */
	ETH->MTLTQOMR |= ETH_MTLTQOMR_TSF; /* TX store-and-forward */
	ETH->MTLRQOMR |= ETH_MTLRQOMR_RSF; /* RX store-and-forward */
	ETH->DMACRCR = (ETH->DMACRCR & ~ETH_DMACRCR_RBSZ_Msk) | (ETH_BUF_SIZE << ETH_DMACRCR_RBSZ_Pos);
	rings_init();

	/* 5. interrupts: RX complete + normal-interrupt summary. */
	ETH->DMACIER = ETH_DMACIER_RIE | ETH_DMACIER_NIE;
	NVIC_EnableIRQ(ETH_IRQn);

	/* 6. go: MAC TX/RX enable (100 Mbit full duplex — LAN8742 auto-neg to 100FD on
	 * the DK), then DMA start. Speed/duplex are re-synced from the PHY in link-up. */
	ETH->MACCR |= ETH_MACCR_FES | ETH_MACCR_DM | ETH_MACCR_TE | ETH_MACCR_RE;
	ETH->DMACTCR |= ETH_DMACTCR_ST;
	ETH->DMACRCR |= ETH_DMACRCR_SR;
	return 0;
}

/* ---------------------------------------------------------------- send ------ */
int eth_send(const uint8_t *frame, uint32_t len) {
	eth_desc_t *d = &tx_desc[tx_idx];
	if ((d->des3 & DESC_OWN) != 0u) {
		return -1; /* DMA still owns it — ring full */
	}
	if (len > ETH_BUF_SIZE) {
		len = ETH_BUF_SIZE;
	}
	memcpy(&tx_buf[tx_idx][0], frame, len);
	d->des0 = (uint32_t)(uintptr_t)&tx_buf[tx_idx][0];
	d->des1 = 0;
	d->des2 = (len & TDES2_B1L_MASK) | TDES2_IOC;
	d->des3 = DESC_OWN | TDES3_FD | TDES3_LD | TDES3_CIC_IPHDR_PL;
	tx_idx = (tx_idx + 1u) % ETH_TX_DESC_CNT;
	/* poke the tail pointer to wake the TX DMA. */
	ETH->DMACTDTPR = (uint32_t)(uintptr_t)&tx_desc[tx_idx];
	return 0;
}

/* ---------------------------------------------------------------- recv ------ */
uint32_t eth_recv(uint8_t *buf, uint32_t buf_size) {
	eth_desc_t *d = &rx_desc[rx_idx];
	if ((d->des3 & DESC_OWN) != 0u) {
		return 0; /* DMA still owns it — nothing received */
	}
	uint32_t len = 0;
	if ((d->des3 & (RDES3_FD | RDES3_LD)) == (RDES3_FD | RDES3_LD)) {
		len = d->des3 & RDES3_PL_MASK;
		if (len > buf_size) {
			len = buf_size;
		}
		memcpy(buf, &rx_buf[rx_idx][0], len);
	}
	/* recycle the descriptor back to the DMA. */
	d->des0 = (uint32_t)(uintptr_t)&rx_buf[rx_idx][0];
	d->des3 = DESC_OWN | RDES3_IOC | RDES3_BUF1V;
	ETH->DMACRDTPR = (uint32_t)(uintptr_t)&rx_desc[rx_idx];
	rx_idx = (rx_idx + 1u) % ETH_RX_DESC_CNT;
	return len;
}

/* ---------------------------------------------------------------- ISR ------- */
void eth_set_rx_callback(void (*cb)(void)) {
	rx_cb = cb;
}

/* The NVIC entry (vectors.S IRQ61). A board.c weak default absorbs it in images
 * that don't link the ETH driver; this strong definition wins in the net image. */
void ETH_IRQHandler(void) {
	uint32_t sr = ETH->DMACSR;
	ETH->DMACSR = sr; /* write-1-clear the pending flags */
	if ((sr & ETH_DMACSR_RI) != 0u && rx_cb != 0) {
		rx_cb(); /* signal the driver's deferred handler (NetX deferred processing) */
	}
}
