/* driver/eth/netx_up.h — the ONE NetX bring-up of a target image. SOME/IP (eth_netx.c) and DoIP
 * (doip_netx.c) attach to it; neither owns NetX, so a node may carry both. */
#ifndef BLOBLY_DRIVER_ETH_NETX_UP_H
#define BLOBLY_DRIVER_ETH_NETX_UP_H

#include "nx_api.h"

/* every timeout in the NetX seams is in ThreadX ticks, and NetX's are too: the two rates must be
 * one (nx_port.h hard-defines NX_IP_PERIODIC_RATE=100 otherwise, and every timeout runs 10x off) */
#if !defined(TX_TIMER_TICKS_PER_SECOND) || TX_TIMER_TICKS_PER_SECOND != NX_IP_PERIODIC_RATE
#error "driver/eth: build with -DTX_TIMER_TICKS_PER_SECOND and -DNX_IP_PERIODIC_RATE equal (1000 on a 1 kHz SysTick)"
#endif
#define MS_TICKS(ms) ((ULONG)(ms) * TX_TIMER_TICKS_PER_SECOND / 1000u)

/* blob_net_up: NetX, the packet pool and the IP instance on the STM32H7 driver, with ARP, ICMP and
 * UDP, at the node's static address (the gateway is the .1 of its /24). The first call does it;
 * a later one with the SAME address is a no-op (0), with another address a refusal (-1) — one
 * address per node. ip_prio is the IP thread's priority, the FIRST caller's: DoIP calls from
 * tx_application_define with loom2v's net_ip_prio — below every application thread, or on an image
 * that also runs an eth thread (SOME/IP) just below the platform threads (comm/eth, io) and above
 * every FB, so the eth thread's traffic is not held behind them; a SOME/IP-only image brings it up
 * from its eth thread at 1.
 * Above the FBs a flood is bounded by the driver's receive budget (net_rx_budget.h): past it the IP
 * thread drains at blob_net_low_prio's priority for the rest of the tick. The IP mutex inherits
 * priority. */
int blob_net_up(const char *addr, unsigned int ip_prio);

/* blob_net_low_prio: the IP thread's priority past the receive budget — below every application
 * thread (loom2v net_target_boot, from tx_application_define, before blob_net_up); unset, the
 * lowest ThreadX priority */
void blob_net_low_prio(unsigned int prio);

NX_IP *blob_net_ip(void);
NX_PACKET_POOL *blob_net_pool(void);
ULONG blob_net_addr(void);

/* blob_net_wait_link: block until the PHY link is up (NX_IP_LINK_ENABLED is reported
 * optimistically, REQ-NET-003, so the PHY is asked too) */
void blob_net_wait_link(void);

/* blob_net_poll_link: one link poll for a service thread (it also resyncs MACCR after a
 * renegotiation, so a cable replug recovers); updates net_link_up */
void blob_net_poll_link(void);

/* blob_net_seed: the TRNG word NetX's rand() starts from (0 = none: the chip id stands in);
 * a nonzero seed also turns on folding a fresh TRNG word into every draw */
void blob_net_seed(unsigned int seed);
int blob_net_seeded(void);

extern volatile ULONG net_link_up;

#endif
