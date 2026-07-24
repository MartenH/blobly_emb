/* bench_util — the three C shims the bulk bench needs for HONEST numbers (codex #216):
 * pin_cpu     — parent and forked child on DISTINCT cores, so the measurement is the
 *               cross-core handoff the ring exists for, not a same-core cache hit;
 * cpu_ns      — CLOCK_PROCESS_CPUTIME_ID, so a 'CPU cost' figure excludes preemption;
 * exited_ok   — WIFEXITED + status 0, so a crashed producer can never print a
 *               near-zero rate as a valid measurement. */
#ifndef BLOBLY_BENCH_UTIL_H
#define BLOBLY_BENCH_UTIL_H
#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <sys/wait.h>
#include <time.h>

static inline int pin_cpu(int cpu)
{
	cpu_set_t s;
	CPU_ZERO(&s);
	CPU_SET(cpu, &s);
	return sched_setaffinity(0, sizeof(s), &s);
}

static inline int64_t cpu_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
	return (int64_t)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

static inline int exited_ok(int status)
{
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

#endif
