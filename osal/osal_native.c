#define _GNU_SOURCE
#include "osal_native.h"
#include <string.h>
#include <sched.h>
#include <pthread.h>

void blob_pin_to_cpu(int cpu) {
#ifdef __linux__
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	/* Best-effort: ignore failure (e.g. fewer host CPUs than partitions). */
	pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#else
	(void)cpu;
#endif
}

/* --- IOC: static slot table, seqlock, last-is-best ---
 *
 * Performance model: lock-free. The writer never blocks (bumps a seq counter
 * around the copy); the reader retries only if it samples mid-write. Valid ONLY
 * for single-writer-per-channel (SPSC) — guaranteed by config: each IOC channel
 * has exactly one `from` partition.
 *
 * Each slot is cache-line aligned and padded to whole cache lines, so a writer
 * on slot A and a writer/reader on slot B never share a line — no false sharing,
 * no cross-core cache ping-pong. This is the difference between "lock-free" and
 * "actually fast" on multicore. */
#define IOC_SLOTS 8
#define IOC_MAX   64
#define CACHELINE 64

typedef struct __attribute__((aligned(CACHELINE))) {
	volatile unsigned seq;       /* even=stable, odd=write in progress, 0=never written */
	unsigned char     len;
	unsigned char     data[IOC_MAX];
	/* pad to a whole number of cache lines so adjacent slots don't share one */
	unsigned char     _pad[2 * CACHELINE - sizeof(unsigned) - 1 - IOC_MAX];
} ioc_slot_t;

static ioc_slot_t g_ioc[IOC_SLOTS] __attribute__((aligned(CACHELINE)));

/* Volatile byte copy: forces real memory access each iteration so the optimizer
 * cannot cache/reorder the seqlock payload load (a plain memcpy of shared data
 * is a data race and miscompiles under -O2 for multi-field records). */
static inline void vcopy(volatile unsigned char *d, volatile const unsigned char *s,
                         unsigned char n) {
	for (unsigned char i = 0; i < n; i++) d[i] = s[i];
}

void blob_ioc_write(int idx, const unsigned char *src, unsigned char len) {
	if (idx < 0 || idx >= IOC_SLOTS || len > IOC_MAX) return;
	ioc_slot_t *s = &g_ioc[idx];
	unsigned seq = __atomic_load_n(&s->seq, __ATOMIC_RELAXED) + 1;
	__atomic_store_n(&s->seq, seq, __ATOMIC_RELAXED); /* mark odd */
	__atomic_thread_fence(__ATOMIC_RELEASE);
	s->len = len;
	vcopy(s->data, src, len);
	__atomic_thread_fence(__ATOMIC_RELEASE);
	__atomic_store_n(&s->seq, seq + 1, __ATOMIC_RELEASE); /* even = published */
}

int blob_ioc_read(int idx, unsigned char *dst, unsigned char max_len) {
	if (idx < 0 || idx >= IOC_SLOTS) return 0;
	ioc_slot_t *s = &g_ioc[idx];
	for (;;) {
		unsigned seq0 = __atomic_load_n(&s->seq, __ATOMIC_ACQUIRE);
		if (seq0 == 0) return 0;   /* never written */
		if (seq0 & 1u) continue;   /* writer mid-update, retry from top */
		unsigned char len = s->len;
		if (len > max_len) len = max_len;
		vcopy(dst, s->data, len);
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		unsigned seq1 = __atomic_load_n(&s->seq, __ATOMIC_ACQUIRE);
		if (seq0 == seq1) return 1; /* stable across the copy -> consistent */
		/* else the writer ran during the copy; retry */
	}
}

/* --- IOC variant 2: lock-free triple buffer (wait-free, non-scalar) ---------
 *
 * Three buffers; the indices {wb (writer-owned), shared (published), rf
 * (reader-owned)} are always a permutation of {0,1,2}, maintained by a single
 * atomic exchange on `shared`. Writer fills its private buffer then swaps it in;
 * reader, if a new value is flagged, swaps its private buffer out for the
 * published one. Neither side ever touches the other's current buffer, so there
 * is no retry and no lock — wait-free both ways, for any payload size. */
#define DB_SLOTS 8
#define DB_DIRTY 0x4u
#define DB_IDX   0x3u

typedef struct __attribute__((aligned(CACHELINE))) {
	unsigned      shared; /* published index | DB_DIRTY (atomic) */
	unsigned      wb;     /* writer-private back-buffer index */
	unsigned      rf;     /* reader-private front-buffer index */
	unsigned char len[3];
	unsigned char buf[3][IOC_MAX];
} db_slot_t;

static db_slot_t g_db[DB_SLOTS];

/* Indices must start as a permutation of {0,1,2}; zero-init would alias them. */
__attribute__((constructor))
static void db_init(void) {
	for (int i = 0; i < DB_SLOTS; i++) {
		__atomic_store_n(&g_db[i].shared, 1u, __ATOMIC_RELAXED); /* clean, no DIRTY */
		g_db[i].wb = 0;
		g_db[i].rf = 2;
	}
}

void blob_ioc_pub(int idx, const unsigned char *src, unsigned char len) {
	if (idx < 0 || idx >= DB_SLOTS || len > IOC_MAX) return;
	db_slot_t *s = &g_db[idx];
	unsigned wb = s->wb;
	s->len[wb] = len;
	memcpy(s->buf[wb], src, len);
	unsigned old = __atomic_exchange_n(&s->shared, wb | DB_DIRTY, __ATOMIC_ACQ_REL);
	s->wb = old & DB_IDX;
}

int blob_ioc_acq(int idx, unsigned char *dst, unsigned char max_len) {
	if (idx < 0 || idx >= DB_SLOTS) return 0;
	db_slot_t *s = &g_db[idx];
	unsigned cur = __atomic_load_n(&s->shared, __ATOMIC_ACQUIRE);
	if (cur & DB_DIRTY) {
		unsigned old = __atomic_exchange_n(&s->shared, s->rf, __ATOMIC_ACQ_REL);
		s->rf = old & DB_IDX;
	}
	unsigned rf = s->rf;
	unsigned char len = s->len[rf];
	if (len > max_len) len = max_len;
	vcopy(dst, s->buf[rf], len);
	return len > 0; /* len 0 == never published */
}

/* --- IOC variant 3: double buffer (2x, wait-free, tear-free if reader keeps up)
 *
 * Writer fills the inactive buffer and atomically flips `active`. Reader copies
 * the active buffer. Wait-free both ways at 2x memory. A torn read is only
 * possible if the writer completes TWO publishes during one read copy (it laps
 * the reader) — i.e. never, when read latency < write interval. */
#define DB2_SLOTS 8

typedef struct __attribute__((aligned(CACHELINE))) {
	unsigned      active; /* index 0/1 of the readable buffer (atomic) */
	unsigned char len[2];
	unsigned char buf[2][IOC_MAX];
} db2_slot_t;

static db2_slot_t g_db2[DB2_SLOTS]; /* zero-init: active=0, len=0 => "no value yet" */

void blob_ioc_pub2(int idx, const unsigned char *src, unsigned char len) {
	if (idx < 0 || idx >= DB2_SLOTS || len > IOC_MAX) return;
	db2_slot_t *s = &g_db2[idx];
	unsigned w = __atomic_load_n(&s->active, __ATOMIC_RELAXED) ^ 1u; /* inactive buffer */
	s->len[w] = len;
	vcopy(s->buf[w], src, len);
	__atomic_store_n(&s->active, w, __ATOMIC_RELEASE); /* publish the flip */
}

int blob_ioc_acq2(int idx, unsigned char *dst, unsigned char max_len) {
	if (idx < 0 || idx >= DB2_SLOTS) return 0;
	db2_slot_t *s = &g_db2[idx];
	unsigned a = __atomic_load_n(&s->active, __ATOMIC_ACQUIRE);
	unsigned char len = s->len[a];
	if (len > max_len) len = max_len;
	vcopy(dst, s->buf[a], len);
	return len > 0;
}
