/* driver/eth/arp_glean.h — the Ethernet source of a received IPv4 frame, read back from the bytes
 * the STM32 NetX driver leaves in front of the IP header (net/nx_driver_stm32h7.c steps the prepend
 * pointer past the 14-byte header and keeps it in the buffer). A pure function, so the rule is
 * host-tested (arp_glean_test.v) and doip_netx.c only feeds it a packet.
 *
 * Why: an answer to a request from a host the board has not resolved yet waits on the board's OWN
 * ARP exchange, and NetX retries an unanswered ARP request only every NX_ARP_UPDATE_RATE (10 s) —
 * so one lost ARP request or reply costs the first answer a tester waits for (#368). The request
 * itself names the MAC it came from; doip_netx.c records it as the peer's ARP entry when there is
 * none, and the answer goes straight back.
 *
 * The 14 bytes are read only when they lie inside the packet buffer, carry the IPv4 EtherType and
 * are addressed to this station (its own MAC, or broadcast): a packet NetX copied or reassembled,
 * or one whose IP options it stripped by moving the header forward, holds something else there,
 * and eight bytes matching by chance are not a risk worth an ARP entry that never expires. Only a
 * unicast source is returned. msw/lsw are NetX's split: the first two octets, then the last four. */
#ifndef BLOBLY_DRIVER_ETH_ARP_GLEAN_H
#define BLOBLY_DRIVER_ETH_ARP_GLEAN_H

#include <stdint.h>

#define ARP_GLEAN_ETH_HDR 14

/* 1 = (msw, lsw) is the unicast source MAC of a frame sent to `self` (or broadcast); 0 = none */
static inline int arp_glean_source(const uint8_t *buf_start, const uint8_t *ip_hdr, const uint8_t self[6],
                                   uint32_t *msw, uint32_t *lsw) {
	if (buf_start == 0 || ip_hdr == 0 || ip_hdr < buf_start || ip_hdr - buf_start < ARP_GLEAN_ETH_HDR) {
		return 0;
	}
	const uint8_t *h = ip_hdr - ARP_GLEAN_ETH_HDR;
	if (h[12] != 0x08u || h[13] != 0x00u) {
		return 0;
	}
	int to_self = 1, to_all = 1;
	for (int i = 0; i < 6; i++) {
		to_self &= h[i] == self[i];
		to_all &= h[i] == 0xFFu;
	}
	if (!to_self && !to_all) {
		return 0;
	}
	const uint8_t *s = h + 6;
	if ((s[0] & 1u) != 0u || (s[0] | s[1] | s[2] | s[3] | s[4] | s[5]) == 0u) {
		return 0; /* multicast / broadcast, or no address */
	}
	*msw = ((uint32_t)s[0] << 8) | (uint32_t)s[1];
	*lsw = ((uint32_t)s[2] << 24) | ((uint32_t)s[3] << 16) | ((uint32_t)s[4] << 8) | (uint32_t)s[5];
	return 1;
}

#endif
