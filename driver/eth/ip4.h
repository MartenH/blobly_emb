/* driver/eth/ip4.h — the static-endpoint address parser the NetX seams share. */
#ifndef BLOBLY_DRIVER_ETH_IP4_H
#define BLOBLY_DRIVER_ETH_IP4_H

#include "nx_api.h"

/* parse one dotted-quad octet run; returns the IP or 0 on a malformed string
 * (0.0.0.0 is not a bindable static endpoint here, so 0 doubles as failure).
 * Every octet must carry at least one digit — "192.168..50" or "192.168.0."
 * would otherwise silently bind a DIFFERENT address than configured. */
static inline ULONG parse_ip4(const char *s) {
	ULONG oct[4] = {0, 0, 0, 0};
	int digits[4] = {0, 0, 0, 0};
	int i = 0;
	for (const char *p = s; *p != '\0'; p++) {
		if (*p == '.') {
			if (++i > 3) {
				return 0;
			}
		} else if (*p >= '0' && *p <= '9') {
			oct[i] = oct[i] * 10u + (ULONG)(*p - '0');
			digits[i]++;
			if (oct[i] > 255u) {
				return 0;
			}
		} else {
			return 0;
		}
	}
	if (i != 3 || digits[0] == 0 || digits[1] == 0 || digits[2] == 0 || digits[3] == 0) {
		return 0;
	}
	return IP_ADDRESS(oct[0], oct[1], oct[2], oct[3]);
}

#endif
