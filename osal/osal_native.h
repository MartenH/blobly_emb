#ifndef BLOBLY_OSAL_NATIVE_H
#define BLOBLY_OSAL_NATIVE_H

/* Host/sim OSAL primitives. The target build replaces these with ThreadX +
 * MPU-backed equivalents; the V side (osal/osal.v) stays identical. */

void blob_pin_to_cpu(int cpu);

/* IOC: inter-core communication. Fixed static slots, seqlock, last-is-best.
 * This is the ONLY memory shared between partitions — on target it lives in an
 * MPU region with directional (writer RW / reader RO) permissions per channel. */
void blob_ioc_write(int idx, const unsigned char *src, unsigned char len);
int  blob_ioc_read(int idx, unsigned char *dst, unsigned char max_len); /* 1=value, 0=never written */

/* IOC variant 2: lock-free TRIPLE BUFFER. Wait-free for BOTH writer and reader
 * (no retry, ever) for arbitrary non-scalar payloads. Single-writer/single-
 * reader, last-is-best. Costs 3x the payload memory; use when a reader must
 * never spin (e.g. hard-real-time) rather than the seqlock's rare retry. */
void blob_ioc_pub(int idx, const unsigned char *src, unsigned char len);
int  blob_ioc_acq(int idx, unsigned char *dst, unsigned char max_len); /* 1=value, 0=none yet */

/* IOC variant 3: DOUBLE BUFFER (2x memory). Wait-free both sides, but tear-free
 * only when the reader keeps up (read latency < write interval) — the common
 * "signals at intervals" case. The memory-conscious middle ground between the
 * 1x seqlock and the 3x triple buffer. On target this slot maps naturally onto
 * a HW-semaphore- or DMA-backed double buffer. */
void blob_ioc_pub2(int idx, const unsigned char *src, unsigned char len);
int  blob_ioc_acq2(int idx, unsigned char *dst, unsigned char max_len);

#endif
