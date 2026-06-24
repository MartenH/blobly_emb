/* The blobly SpeedMonitor demo running on ThreadX AMP.
 *
 * Two ThreadX kernels (one per forked, pinned core), each running a Loom-style
 * periodic dispatch as a ThreadX thread, exchanging signals through blobly's
 * real lock-free IOC in shared memory:
 *
 *   core0 (IO partition):  sweep VehicleSpeed 0..290 km/h -> IOC ch0;
 *                          read WarnLamp <- IOC ch1; print the trace.
 *   core1 (App partition):  SpeedMonitor: lamp.on = (kph > 120) -> IOC ch1.
 *
 * Same behavior as main.v, but scheduled by ThreadX instead of the host sim. */
#define _GNU_SOURCE
#include "tx_api.h"
#include <sched.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/wait.h>

/* blobly IOC shim (compiled in) */
extern void  blob_ioc_shared_init(void);
extern void  blob_ioc_pub(int, const unsigned char *, unsigned char);
extern int   blob_ioc_acq(int, unsigned char *, unsigned char);
extern void *blob_shared_scratch(void);
extern void  blob_pin_to_cpu(int);

#define CH_SPEED 0 /* IO  -> App */
#define CH_LAMP  1 /* App -> IO  */
#define CYCLES   30
#define STOP_FLAG 7 /* scratch[7]: tell the App partition to exit */

/* Typed ports (mirror app/speed_monitor.v) */
typedef struct { uint16_t kph; uint8_t valid; } VehicleSpeed;
typedef struct { uint8_t on; } WarnLamp;

static int      g_core;
static TX_THREAD g_thread;
static UCHAR     g_stack[32 * 1024];

/* The App partition's handler — the SpeedMonitor decision, verbatim. */
static void speed_monitor_on_tick(const VehicleSpeed *speed, WarnLamp *lamp) {
	lamp->on = (speed->valid && speed->kph > 120) ? 1 : 0;
}

/* core1: App partition — Loom dispatch as a ThreadX thread, ~10ms period. */
static void app_partition(ULONG in) {
	(void)in;
	volatile uint64_t *stop = (uint64_t *)blob_shared_scratch();
	while (!stop[STOP_FLAG]) {
		VehicleSpeed speed = {0, 0};
		blob_ioc_acq(CH_SPEED, (unsigned char *)&speed, sizeof(speed));
		WarnLamp lamp = {0};
		speed_monitor_on_tick(&speed, &lamp);
		blob_ioc_pub(CH_LAMP, (unsigned char *)&lamp, sizeof(lamp));
		tx_thread_sleep(1); /* 10 ms at 100 ticks/s */
	}
	_exit(0);
}

/* core0: IO partition — sweep speed, read lamp back, trace it. ~30ms period. */
static void io_partition(ULONG in) {
	(void)in;
	uint64_t *scratch = (uint64_t *)blob_shared_scratch();
	int first_on = -1;
	printf("SpeedMonitor on ThreadX AMP (core0=IO, core1=App, IOC shared):\n");
	for (int cycle = 0; cycle < CYCLES; cycle++) {
		VehicleSpeed vs = {(uint16_t)(cycle * 10), 1};
		blob_ioc_pub(CH_SPEED, (unsigned char *)&vs, sizeof(vs));
		tx_thread_sleep(3); /* 30 ms: let the App partition run */
		WarnLamp lamp = {0};
		blob_ioc_acq(CH_LAMP, (unsigned char *)&lamp, sizeof(lamp));
		if (lamp.on && first_on < 0) first_on = vs.kph;
		if (cycle % 5 == 0 || (lamp.on && first_on == vs.kph))
			printf("  kph=%3u -> lamp=%u%s\n", vs.kph, lamp.on,
			       (lamp.on && first_on == vs.kph) ? "   <- threshold crossed" : "");
	}
	scratch[STOP_FLAG] = 1; /* stop the App partition */
	printf("lamp first turned ON at kph=%d (expected 130, i.e. first >120)\n", first_on);
	_exit(0);
}

void tx_application_define(void *first_unused_memory) {
	(void)first_unused_memory;
	blob_pin_to_cpu(g_core);
	if (g_core == 0)
		tx_thread_create(&g_thread, "io", io_partition, 0, g_stack, sizeof(g_stack),
		                 1, 1, TX_NO_TIME_SLICE, TX_AUTO_START);
	else
		tx_thread_create(&g_thread, "app", app_partition, 0, g_stack, sizeof(g_stack),
		                 1, 1, TX_NO_TIME_SLICE, TX_AUTO_START);
}

int main(void) {
	setvbuf(stdout, NULL, _IONBF, 0); /* unbuffered: _exit() in children won't drop output */
	blob_ioc_shared_init();
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
	return 0;
}
