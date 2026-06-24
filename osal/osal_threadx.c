/* ThreadX OSAL backend (host AMP). Compiled into the binary always, but inert
 * unless BLOBLY_THREADX is defined (set by the `make demo-threadx` build, which
 * also passes -d threadx to V and links ThreadX). One ThreadX kernel per forked,
 * pinned process = one AMP core; the partition's V entry runs as a ThreadX thread.
 * The IOC + shared memory + waitpid live in osal_native.c and are reused as-is. */
#ifdef BLOBLY_THREADX
#define _GNU_SOURCE
#include "tx_api.h"
#include <unistd.h>

extern void blob_pin_to_cpu(int);

/* One partition per process => one ThreadX thread per kernel. */
static void (*g_entry)(int, void *);
static void *g_arg;
static int   g_core;
static TX_THREAD g_part_thread;
static UCHAR     g_part_stack[64 * 1024];

static void part_trampoline(ULONG in) {
	(void)in;
	g_entry(g_core, g_arg); /* run the V partition entry as a ThreadX thread */
	_exit(0);
}

/* ThreadX calls this after _tx_initialize_low_level, inside tx_kernel_enter. */
void tx_application_define(void *first_unused_memory) {
	(void)first_unused_memory;
	blob_pin_to_cpu(g_core); /* deterministic core (override the port's random pin) */
	tx_thread_create(&g_part_thread, "partition", part_trampoline, 0,
	                 g_part_stack, sizeof(g_part_stack), 1, 1,
	                 TX_NO_TIME_SLICE, TX_AUTO_START);
}

/* osal.start_core under -d threadx: fork a process per core; the child enters
 * ThreadX (never returns) and runs `entry` as its single ThreadX thread. */
int blob_tx_start_core(int core_id, void (*entry)(int, void *), void *arg) {
	pid_t pid = fork();
	if (pid == 0) {
		g_core = core_id;
		g_entry = entry;
		g_arg = arg;
		blob_pin_to_cpu(core_id);
		tx_kernel_enter(); /* never returns */
		_exit(0);
	}
	return (int)pid;
}

/* osal.sleep_us under -d threadx: yield via the ThreadX scheduler (10ms tick). */
void blob_tx_sleep_us(unsigned long long us) {
	ULONG ticks = (ULONG)(us / 10000); /* 100 ticks/s => 10 ms per tick */
	if (ticks == 0) ticks = 1;
	tx_thread_sleep(ticks);
}
#endif /* BLOBLY_THREADX */
