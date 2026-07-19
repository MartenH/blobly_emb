/* h755_io target glue: the cross-thread signal IOC pool (boards/common/ioc.h).
 *
 * GENERIC target glue, config-independent (the comm_glue.c pattern): a small indexed
 * pool the generator assigns cells out of, so io signals cross between the platform io
 * thread and the FB thread without a lock (the blobly IOC invariant). V can't express
 * the atomics/volatile, so it calls these scalar wrappers by cell index; loom2v wires
 * which index carries which signal. No comm thread in this example — this file is the
 * whole glue.
 */
#include "ioc.h"

#define IOC_POOL_N 4
static ioc_t g_ioc_pool[IOC_POOL_N];
void ioc_pool_init(void) {
    for (int i = 0; i < IOC_POOL_N; i++) ioc_init(&g_ioc_pool[i]);
}
void ioc_pub(int i, unsigned a, unsigned b) {
    sig_t v = { a, b };
    if (i >= 0 && i < IOC_POOL_N) ioc_write(&g_ioc_pool[i], v);
}
/* One ioc_read per logical read (it advances the reader's private slot), returning both fields. */
void ioc_get(int i, unsigned *a, unsigned *b) {
    sig_t v = { 0, 0 };
    if (i >= 0 && i < IOC_POOL_N) v = ioc_read(&g_ioc_pool[i]);
    *a = v.a; *b = v.b;
}
/* ioc_get_ever — the ever-published gate (docs/io.md, REQ-IO-009): returns 1 once the
 * cell has EVER been published, latched from the fresh bit BEFORE ioc_read consumes
 * it; *a/*b always hold the latest value. Until then the io thread keeps the driver-
 * established init on an output pin, and an FB handler keeps an input port's declared
 * default (a zero slot is not a sample). seen[] is per-cell and each cell has exactly
 * ONE reader (io thread: outputs; FB thread: inputs) — disjoint bytes, no race. */
int ioc_get_ever(int i, unsigned *a, unsigned *b) {
    static unsigned char seen[IOC_POOL_N];
    if (i < 0 || i >= IOC_POOL_N) { *a = 0; *b = 0; return 0; }
    if (__atomic_load_n(&g_ioc_pool[i].shared, __ATOMIC_ACQUIRE) & IOC_FRESH) seen[i] = 1;
    sig_t v = ioc_read(&g_ioc_pool[i]);
    *a = v.a; *b = v.b;
    return seen[i];
}

/* vectors.S references FDCAN1_IT0_IRQHandler unconditionally (never weak-aliased — see
 * the note there). No comm thread in this image, so the Rx interrupt is never enabled;
 * a parked stub satisfies the link and would trap loudly if it ever fired (the
 * m4_glue.c pattern). */
void FDCAN1_IT0_IRQHandler(void) {
    for (;;) {
    }
}
