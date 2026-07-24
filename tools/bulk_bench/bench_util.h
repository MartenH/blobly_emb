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

/* partner_cpu — a CPU on a DIFFERENT physical core than cpu 0: on SMT hosts logical
 * 0/1 are often hyper-siblings sharing L1/L2, which would inflate a "cross-core"
 * number (codex #216 r4). Scans core_id sysfs entries; falls back to 1 when the
 * topology is unreadable (bare containers) — the caller labels honestly either way. */
#include <stdio.h>
static inline int core_id_of(int cpu)
{
	char path[96];
	snprintf(path, sizeof(path),
	         "/sys/devices/system/cpu/cpu%d/topology/core_id", cpu);
	FILE *f = fopen(path, "r");
	if (!f) return -1;
	int id = -1;
	if (fscanf(f, "%d", &id) != 1) id = -1;
	fclose(f);
	return id;
}

/* Returns -1 when a distinct physical core CANNOT be verified (unreadable topology,
 * or a machine where every visible CPU shares cpu0's core): the bench REFUSES to run
 * rather than print "distinct physical cores" about siblings (codex #216 r5). */
static inline int partner_cpu(void)
{
	int base = core_id_of(0);
	if (base < 0) return -1;
	for (int c = 1; c < 64; c++) {
		int id = core_id_of(c);
		if (id < 0) break;
		if (id != base) return c;
	}
	return -1;
}

/* the cross-process stop flag rides the same discipline as the bulk cursors:
 * volatile 32-bit accesses — a plain load under -prod may retain a stale zero
 * forever (codex #216 r5) */
static inline void stop_set(void *p) { *(volatile uint32_t *)p = 1u; }
static inline uint32_t stop_get(void *p) { return *(volatile uint32_t *)p; }

static inline int exited_ok(int status)
{
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

#endif
