/* boards/h735dk/eth.c — STM32H735 Ethernet MAC/DMA + LAN8742A RMII driver.
 *
 * The register-level hardware half of the on-target TCP/IP stack (docs/net.md).
 * Register sequences follow RM0468 (H72x/H73x, the DWC_ether_qos MAC) and the ST
 * HAL bring-up order. D-cache is OFF on this board (docs/no-alloc.md), so DMA
 * descriptors/buffers need NO clean+invalidate — a real simplification here.
 *
 * BENCH-VERIFIED on the H735-DK (2026-07-18): link + ARP + ICMP both directions,
 * 0% loss at ~1 ms RTT. Two silicon-found bugs live in this file's history: the
 * DSB-before-doorbell ordering (see eth_send) and TX checksum-offload vs NetX
 * software checksums. Pinout is the CONFIRMED MB1520 map (docs/net.md), AF11.
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

/* bench-observable frame counters (read over SWD) — cheap, and they were how the
 * P1 bring-up bugs were found; keep them. */
volatile uint32_t eth_rx_count;
volatile uint32_t eth_tx_count;
volatile uint32_t eth_isr_count;
volatile uint32_t eth_tx_drops;  /* eth_send calls refused because the ring was full */
volatile uint32_t eth_phy_pscsr; /* LAN8742 reg31: negotiated speed/duplex */

/* eth_multicast_all: coarse multicast enable (MACPFR.PM, pass-all-multicast).
 * Called on the first NetX MULTICAST_JOIN; NetX does the precise per-group
 * filtering in software, so per-address hash filtering would be bloat here. */
void eth_multicast_all(void) {
	ETH->MACPFR |= ETH_MACPFR_PM;
}

/* eth_unique_mac: a locally-administered MAC derived from the STM32 96-bit unique
 * device ID — two boards running the same image must not share an address (ARP
 * caches/switch tables flap). 0x02 prefix = locally administered, unicast. */
void eth_unique_mac(uint8_t mac[6]) {
	const volatile uint32_t *uid = (const volatile uint32_t *)UID_BASE;
	uint32_t mix = uid[0] ^ (uid[1] << 1) ^ (uid[2] << 2);
	mac[0] = 0x02u;
	mac[1] = (uint8_t)(uid[2] >> 8);
	mac[2] = (uint8_t)(mix >> 24);
	mac[3] = (uint8_t)(mix >> 16);
	mac[4] = (uint8_t)(mix >> 8);
	mac[5] = (uint8_t)mix;
}

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

/* ------------------------------------------------------------------ MDIO ---- */
/* The MAC's MDIO clause-22 access (MACMDIOAR/MACMDIODR). CR = clock-range divider
 * for the MDC: HCLK is 275 MHz here, so the 250-300 MHz range (DIV124) is the one
 * that keeps MDC under the PHY's 2.5 MHz limit — 275/124 = 2.2 MHz. (The 150-250
 * range's DIV102 would give 2.7 MHz: over-spec, worked on one bench, not reliable.) */
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
	            | ETH_MACMDIOAR_CR_DIV124
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
	            | ETH_MACMDIOAR_CR_DIV124
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

/* phy_sync_maccr: apply the PHY's NEGOTIATED speed/duplex (PSCSR reg 31,
 * bits[4:2]: bit1 of the field = 100 Mbit, bit2 = full duplex) to MACCR. Falls
 * back to 100M/full if the field reads 0 (autoneg not settled). Idempotent. */
static void phy_sync_maccr(void) {
	uint16_t pscsr = 0;
	(void)phy_read(31u, &pscsr);
	eth_phy_pscsr = pscsr;
	uint32_t spd = ((uint32_t)pscsr >> 2) & 0x7u;
	uint32_t maccr = ETH->MACCR & ~(ETH_MACCR_FES | ETH_MACCR_DM);
	if (spd == 0u) {
		maccr |= ETH_MACCR_FES | ETH_MACCR_DM;
	} else {
		if ((spd & 0x2u) != 0u) {
			maccr |= ETH_MACCR_FES; /* 100 Mbit (else 10) */
		}
		if ((spd & 0x4u) != 0u) {
			maccr |= ETH_MACCR_DM; /* full duplex (else half) */
		}
	}
	if (maccr != ETH->MACCR) {
		ETH->MACCR = maccr;
	}
}

int eth_link_up(void) {
	uint16_t bsr;
	if (phy_read(1u, &bsr) != 0) {
		return 0;
	}
	if ((bsr & 0x0004u) == 0u) {
		return 0;
	}
	/* Link is up: re-sync MACCR with what THIS link actually negotiated — covers
	 * the boot-without-cable case where eth_init's bounded autoneg wait fell back
	 * to a guess (a 10M/half partner would otherwise never communicate). */
	phy_sync_maccr();
	return 1;
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
	__DSB(); /* ring contents visible before the DMA is started */
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
	/* Perfect filter (MACPFR reset value 0): accept unicast matching MACA0 +
	 * broadcast. NOT promiscuous — on a busy network promiscuous floods the small
	 * RX ring and crowds out our own reply traffic (bench: ~50% ICMP loss). */
	if (phy_bringup() != 0) {
		return -2;
	}

	/* 4. DMA bus mode + per-channel control; TX/RX store-and-forward in the MTL. */
	ETH->DMASBMR |= ETH_DMASBMR_AAL;   /* address-aligned beats */
	ETH->MTLTQOMR |= ETH_MTLTQOMR_TSF; /* TX store-and-forward */
	ETH->MTLRQOMR |= ETH_MTLRQOMR_RSF; /* RX store-and-forward */
	ETH->DMACRCR = (ETH->DMACRCR & ~ETH_DMACRCR_RBSZ_Msk) | (ETH_BUF_SIZE << ETH_DMACRCR_RBSZ_Pos);
	rings_init();

	/* 5. interrupts: RX complete + normal-interrupt summary on the DMA side, and
	 * MASK the MMC statistics counters — their half/full-rollover interrupts are
	 * unmasked at reset and share ETH_IRQn, but our handler only clears DMACSR:
	 * an unmasked MMC source would storm the CPU on a long/busy run. */
	ETH->MMCRIMR = ETH_MMCRIMR_RXLPITRCIM | ETH_MMCRIMR_RXLPIUSCIM
	             | ETH_MMCRIMR_RXUCGPIM | ETH_MMCRIMR_RXALGNERPIM | ETH_MMCRIMR_RXCRCERPIM;
	ETH->MMCTIMR = ETH_MMCTIMR_TXLPITRCIM | ETH_MMCTIMR_TXLPIUSCIM
	             | ETH_MMCTIMR_TXGPKTIM | ETH_MMCTIMR_TXMCOLGPIM | ETH_MMCTIMR_TXSCOLGPIM;
	ETH->DMACIER = ETH_DMACIER_RIE | ETH_DMACIER_NIE;
	NVIC_EnableIRQ(ETH_IRQn);

	/* 6. match the MAC to the PHY's AUTO-NEGOTIATED speed/duplex — a hardcoded
	 * mismatch (MAC full-duplex on a half-duplex link) is the classic ~50%-loss
	 * cause. Bounded wait for autoneg (BSR bit5), then sync; if the cable is
	 * absent at boot this falls back to 100M/full and eth_link_up() re-syncs when
	 * a link actually comes up. */
	/* Each iteration is one MDIO read = 64 MDC bits at 2.2 MHz ~= 29 us, so the
	 * bound is the autoneg budget: 140k * 29 us ~= 4 s (802.3 settles in < 3 s).
	 * No cable -> falls through after ~4 s; eth_link_up() re-syncs on late plug. */
	uint16_t bsr = 0;
	for (uint32_t t = 0; t < 140000u; t++) {
		if (phy_read(1u, &bsr) == 0 && (bsr & 0x0020u) != 0u) {
			break; /* auto-negotiation complete */
		}
	}
	phy_sync_maccr();
	ETH->MACCR |= ETH_MACCR_TE | ETH_MACCR_RE;
	ETH->DMACTCR |= ETH_DMACTCR_ST;
	ETH->DMACRCR |= ETH_DMACRCR_SR;
	return 0;
}

/* ---------------------------------------------------------------- send ------ */
int eth_send(const uint8_t *frame, uint32_t len) {
	eth_desc_t *d = &tx_desc[tx_idx];
	uint32_t next = (tx_idx + 1u) % ETH_TX_DESC_CNT;
	/* N-1 rule: also require the NEXT slot (the tail target) to be free. If the
	 * tail wrapped onto a still-OWNed descriptor it could equal the DMA's current
	 * pointer, which the H7 DMA reads as "no work" — all pending frames hang and
	 * every later send drops: a permanent TX wedge. One reserved slot ends that. */
	if ((d->des3 & DESC_OWN) != 0u || (tx_desc[next].des3 & DESC_OWN) != 0u) {
		eth_tx_drops++; /* ring full: drop (Ethernet is lossy; protocols retry) */
		return -1;
	}
	if (len > ETH_BUF_SIZE) {
		len = ETH_BUF_SIZE;
	}
	memcpy(&tx_buf[tx_idx][0], frame, len);
	d->des0 = (uint32_t)(uintptr_t)&tx_buf[tx_idx][0];
	d->des1 = 0;
	d->des2 = (len & TDES2_B1L_MASK) | TDES2_IOC;
	/* NO hardware checksum insertion (CIC=0): NetX computes IP/ICMP/TCP/UDP
	 * checksums in software, and letting the MAC also insert would OVERWRITE the
	 * correct value with a (for ICMP, wrong) recompute — the frame is then dropped
	 * by the peer. ARP has no checksum, which is why it worked and ping didn't. */
	d->des3 = DESC_OWN | TDES3_FD | TDES3_LD;
	tx_idx = (tx_idx + 1u) % ETH_TX_DESC_CNT;
	/* DSB: the descriptor stores (normal memory, D2 SRAM) must be visible BEFORE
	 * the tail-pointer doorbell (device memory) — the M7 store buffer otherwise
	 * lets the doorbell arrive first, the DMA fetches the descriptor with OWN
	 * still 0 and goes idle, and the frame only leaves on the NEXT doorbell
	 * (bench: every TX one frame behind, frames leaving in back-to-back pairs). */
	__DSB();
	/* poke the tail pointer to wake the TX DMA. */
	ETH->DMACTDTPR = (uint32_t)(uintptr_t)&tx_desc[tx_idx];
	eth_tx_count++;
	return 0;
}

/* ---------------------------------------------------------------- recv ------ */
uint32_t eth_recv(uint8_t *buf, uint32_t buf_size) {
	/* Loop past bad/context/fragmented descriptors: returning 0 for one of those
	 * would be indistinguishable from "ring empty" and strand any good frames
	 * queued behind it until the next interrupt. 0 means ONLY "nothing pending". */
	for (;;) {
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
			eth_rx_count++;
		}
		/* recycle the descriptor back to the DMA (DSB: same store-ordering rule
		 * as eth_send — OWN must be visible before the doorbell). */
		d->des0 = (uint32_t)(uintptr_t)&rx_buf[rx_idx][0];
		d->des3 = DESC_OWN | RDES3_IOC | RDES3_BUF1V;
		__DSB();
		ETH->DMACRDTPR = (uint32_t)(uintptr_t)&rx_desc[rx_idx];
		rx_idx = (rx_idx + 1u) % ETH_RX_DESC_CNT;
		if (len != 0u) {
			return len;
		}
	}
}

/* ---------------------------------------------------------------- ISR ------- */
void eth_set_rx_callback(void (*cb)(void)) {
	rx_cb = cb;
}

/* The NVIC entry (vectors.S IRQ61). A board.c weak default absorbs it in images
 * that don't link the ETH driver; this strong definition wins in the net image. */
void ETH_IRQHandler(void) {
	eth_isr_count++;
	uint32_t sr = ETH->DMACSR;
	ETH->DMACSR = sr; /* write-1-clear the pending flags */
	if ((sr & ETH_DMACSR_RI) != 0u && rx_cb != 0) {
		rx_cb(); /* signal the driver's deferred handler (NetX deferred processing) */
	}
}
