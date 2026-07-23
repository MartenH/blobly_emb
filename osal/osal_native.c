#define _GNU_SOURCE
#include "osal_native.h"
#include <string.h>
#include <sched.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

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

/* ============================================================================
 * IOC slot types. Each slot is cache-line aligned + padded so a writer on one
 * channel never shares a line with another channel (no false sharing).
 * ==========================================================================*/
/* Channel-pool sizes (host/sim defaults). Sized so larger configs — e.g. the
 * `scale` benchmark example (4 cores, 8 buses, ~200 FBs) — fit; small examples
 * use only the low indices. On target the OSAL backend sizes these to the
 * generated channel count. */
#define IOC_SLOTS 256
#define IOC_MAX   64
#define CACHELINE 64
#define DB_SLOTS  256
#define DB_DIRTY  0x4u
#define DB_IDX    0x3u
#define DB2_SLOTS 256

typedef struct __attribute__((aligned(CACHELINE))) {
	volatile unsigned seq; /* even=stable, odd=write in progress, 0=never written */
	unsigned char     len;
	unsigned char     data[IOC_MAX];
	unsigned char     _pad[2 * CACHELINE - sizeof(unsigned) - 1 - IOC_MAX];
} ioc_slot_t;

typedef struct __attribute__((aligned(CACHELINE))) {
	unsigned      shared; /* published index | DB_DIRTY (atomic) */
	unsigned      wb;     /* writer-private back-buffer index */
	unsigned      rf;     /* reader-private front-buffer index */
	unsigned char len[3];
	unsigned char buf[3][IOC_MAX];
} db_slot_t;

typedef struct __attribute__((aligned(CACHELINE))) {
	unsigned      active; /* index 0/1 of the readable buffer (atomic) */
	unsigned char len[2];
	unsigned char buf[2][IOC_MAX];
} db2_slot_t;

/* All cross-core IOC state in one block. For AMP this is placed in a shared
 * region (mmap MAP_SHARED) before fork, so every per-core process shares it —
 * the host-Linux equivalent of the target's shared SRAM. */
typedef struct {
	ioc_slot_t         ioc[IOC_SLOTS];
	db_slot_t          db[DB_SLOTS];
	db2_slot_t         db2[DB2_SLOTS];
	unsigned long long scratch[16]; /* small shared scratch (bench results, etc.) */
} ioc_shared_t;

static ioc_shared_t  g_static __attribute__((aligned(CACHELINE)));
static ioc_shared_t *g_shared = &g_static; /* single-process default; AMP swaps to mmap */

/* Access the live region through the pointer, so single-process and AMP share code. */
#define g_ioc (g_shared->ioc)
#define g_db  (g_shared->db)
#define g_db2 (g_shared->db2)

/* Triple-buffer indices must start as a permutation of {0,1,2}, not zero. */
static void init_db_indices(ioc_shared_t *s) {
	for (int i = 0; i < DB_SLOTS; i++) {
		__atomic_store_n(&s->db[i].shared, 1u, __ATOMIC_RELAXED); /* clean, no DIRTY */
		s->db[i].wb = 0;
		s->db[i].rf = 2;
	}
}

__attribute__((constructor))
static void ioc_ctor(void) { init_db_indices(&g_static); }

/* blob_ioc_shared_init: move the IOC region into shared memory. MUST be called
 * before blob_start_core (fork), so all per-core processes see the same slots. */
void blob_ioc_shared_init(void) {
	if (g_shared != &g_static) return; /* already shared */
	void *p = mmap(NULL, sizeof(ioc_shared_t), PROT_READ | PROT_WRITE,
	               MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) return;
	memset(p, 0, sizeof(ioc_shared_t));
	g_shared = (ioc_shared_t *)p;
	init_db_indices(g_shared);
}

void *blob_shared_scratch(void) { return (void *)g_shared->scratch; }

/* blob_start_core: AMP core bring-up. fork() a process per core, pin it, and run
 * the entry there. Real OS-level parallelism (one process per physical CPU),
 * sharing only the mmap'd IOC region. */
int blob_start_core(int core_id, void (*entry)(int, void *), void *arg) {
	pid_t pid = fork();
	if (pid == 0) {
		blob_pin_to_cpu(core_id);
		entry(core_id, arg);
		_exit(0);
	}
	return (int)pid;
}

int blob_wait_core(int pid) {
	int status = 0;
	waitpid((pid_t)pid, &status, 0);
	return status;
}

/* Volatile byte copy: forces real memory access each iteration so the optimizer
 * cannot cache/reorder the seqlock payload load. */
static inline void vcopy(volatile unsigned char *d, volatile const unsigned char *s,
                         unsigned char n) {
	for (unsigned char i = 0; i < n; i++) d[i] = s[i];
}

/* --- IOC variant 1: seqlock (1x, reader may retry) -------------------------*/
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
	}
}

/* --- IOC variant 2: lock-free triple buffer (wait-free, non-scalar) --------*/
void blob_ioc_pub(int idx, const unsigned char *src, unsigned char len) {
	if (idx < 0 || idx >= DB_SLOTS || len > IOC_MAX) return;
	db_slot_t *s = &g_db[idx];
	unsigned wb = s->wb;
	s->len[wb] = len;
	vcopy(s->buf[wb], src, len);
	unsigned old = __atomic_exchange_n(&s->shared, wb | DB_DIRTY, __ATOMIC_ACQ_REL);
	s->wb = old & DB_IDX;
}

/* Like blob_ioc_acq, but reports PUBLICATION freshness: returns 1 only when this call
 * consumed a buffer the writer flipped since our previous acquire (DB_DIRTY), 0 when it
 * served the cached last-good value. Needed by consumers with a staleness deadline (the
 * route crossing): "ever written" freshness lets one old frame satisfy the deadline
 * forever (codex on #200). Tear-free like acq — the exchange takes whole-buffer ownership. */
int blob_ioc_acq_fresh(int idx, unsigned char *dst, unsigned char max_len) {
	if (idx < 0 || idx >= DB_SLOTS) return 0;
	db_slot_t *s = &g_db[idx];
	int fresh = 0;
	unsigned cur = __atomic_load_n(&s->shared, __ATOMIC_ACQUIRE);
	if (cur & DB_DIRTY) {
		unsigned old = __atomic_exchange_n(&s->shared, s->rf, __ATOMIC_ACQ_REL);
		s->rf = old & DB_IDX;
		fresh = 1;
	}
	unsigned rf = s->rf;
	unsigned char len = s->len[rf];
	if (len > max_len) len = max_len;
	vcopy(dst, s->buf[rf], len);
	return fresh && len > 0;
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
	return len > 0;
}

/* --- IOC variant 3: double buffer (2x, wait-free if reader keeps up) -------*/
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
