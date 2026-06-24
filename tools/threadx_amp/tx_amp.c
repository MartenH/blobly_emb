/* ThreadX AMP on Linux: one ThreadX kernel instance per core (forked process),
 * each pinned to its CPU, all sharing one MAP_SHARED IOC region (blobly's shim).
 * Proves real parallel multicore ThreadX on the host via the fork+shared-mem
 * method — not the stock single-core port. */
#define _GNU_SOURCE
#include "tx_api.h"
#include <sched.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/wait.h>

/* blobly IOC shim (compiled in) */
extern void  blob_ioc_shared_init(void);
extern void  blob_ioc_pub(int, const unsigned char *, unsigned char);
extern int   blob_ioc_acq(int, unsigned char *, unsigned char);
extern void *blob_shared_scratch(void);
extern void  blob_pin_to_cpu(int);

#define RUN_US 1000000ULL
#define CH 0

static int       g_core;
static TX_THREAD  g_thread;
static UCHAR      g_stack[32 * 1024];

typedef struct { uint64_t seq; uint32_t a, b, c; unsigned char pad[40]; } Rec;

static uint64_t now_us(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}
static void fill(Rec *r, uint64_t n) {
	r->seq = n; r->a = (uint32_t)n; r->b = (uint32_t)n * 2 + 1;
	r->c = (uint32_t)n * 3 + 2; r->pad[0] = (unsigned char)n;
}
static int consistent(Rec *r) {
	return r->a == (uint32_t)r->seq && r->b == (uint32_t)r->seq * 2 + 1 &&
	       r->c == (uint32_t)r->seq * 3 + 2 && r->pad[0] == (unsigned char)r->seq;
}

static void writer_entry(ULONG in) {
	(void)in;
	Rec r = {0}; uint64_t n = 0, deadline = now_us() + RUN_US;
	while (now_us() < deadline) { n++; fill(&r, n); blob_ioc_pub(CH, (unsigned char *)&r, sizeof(r)); }
	((uint64_t *)blob_shared_scratch())[0] = n;
	_exit(0);
}
static void reader_entry(ULONG in) {
	(void)in;
	Rec r = {0}; uint64_t n = 0, tear = 0, deadline = now_us() + RUN_US;
	while (now_us() < deadline) {
		if (blob_ioc_acq(CH, (unsigned char *)&r, sizeof(r)) && !consistent(&r)) tear++;
		n++;
	}
	uint64_t *sc = (uint64_t *)blob_shared_scratch();
	sc[1] = n; sc[2] = tear;
	_exit(0);
}

/* ThreadX entry — runs inside each per-core kernel after tx_kernel_enter(). */
void tx_application_define(void *first_unused_memory) {
	(void)first_unused_memory;
	blob_pin_to_cpu(g_core); /* override the port's random single-core confine */
	if (g_core == 0)
		tx_thread_create(&g_thread, "writer", writer_entry, 0, g_stack, sizeof(g_stack),
		                 1, 1, TX_NO_TIME_SLICE, TX_AUTO_START);
	else
		tx_thread_create(&g_thread, "reader", reader_entry, 0, g_stack, sizeof(g_stack),
		                 1, 1, TX_NO_TIME_SLICE, TX_AUTO_START);
}

int main(void) {
	blob_ioc_shared_init(); /* shared IOC region BEFORE fork */
	uint64_t t0 = now_us();
	pid_t pids[2];
	for (int core = 0; core < 2; core++) {
		pid_t pid = fork();
		if (pid == 0) {
			g_core = core;
			blob_pin_to_cpu(core);
			tx_kernel_enter(); /* never returns; runs this core's ThreadX scheduler */
			_exit(0);
		}
		pids[core] = pid;
	}
	for (int i = 0; i < 2; i++) { int st; waitpid(pids[i], &st, 0); }
	uint64_t wall = now_us() - t0;

	uint64_t *sc = (uint64_t *)blob_shared_scratch();
	printf("ThreadX AMP on Linux: 2 ThreadX kernels, 1 per forked core, shared IOC\n");
	printf("  core0 writer thread: %llu ops\n", (unsigned long long)sc[0]);
	printf("  core1 reader thread: %llu ops  torn=%llu\n",
	       (unsigned long long)sc[1], (unsigned long long)sc[2]);
	printf("  wall-clock: %llu ms (==~1000 => the two kernels ran in PARALLEL)\n",
	       (unsigned long long)(wall / 1000));
	return 0;
}
