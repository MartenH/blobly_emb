/* boot_net.c — the boot manager's network half, for a [boot] node that serves DoIP too ([doip];
 * boot/boot.mk links it, with ThreadX, NetX and driver/eth/doip_netx.c). The happy path never gets
 * here: the boot decision and the jump run first, from near-reset state, before any kernel. On the
 * stay path the boot enters ThreadX, so the application's own DoIP seam can run unchanged:
 *
 *   boot                              — the serve loop (boot/target, blobly_boot_serve): the bus,
 *                                       the DoIP mailbox, the stay-window. HIGHEST priority, so a
 *                                       LAN flood cannot starve an ISO-TP transfer on the bus; it
 *                                       rests a tick whenever nothing is in flight on the bus
 *                                       (boot_net_rest), woken early by a DoIP request
 *   the IP thread, doip and doip-svc  — doip_netx.c's, at the application's address, below it
 *
 * The entity is the application's (gen/boot_gen.h, from the node's [doip]): the same address,
 * logical address, VIN and routing-activation policy, so a tester reconnects to the bootloader
 * exactly as it connected to the application. All memory static. */
#include <stdint.h>
#include "tx_api.h"
#include "boot_gen.h"

#if !defined(BOOT_DOIP)
#error "boot_net.c: gen/boot_gen.h declares no DoIP entity — link this only for a [doip] node (boot/boot.mk)"
#endif

int doip_net_create(const char *addr, unsigned int ip_prio, unsigned int prio);
void doip_net_timers(unsigned int initial_ms, unsigned int general_ms);
void doip_net_seed(unsigned int seed);
int diag_sa_init(void);
int diag_sa_seed(uint8_t *out, int n);
extern void blobly_boot_serve(void);    /* boot/target: never returns */
extern void blobly_boot_net_init(void); /* boot/target: the entity's identity and the mailbox */

#define SERVE_PRIO 1 /* the serve loop */
#define IP_PRIO 2    /* NetX's IP thread */
#define NET_PRIO 3   /* doip, doip-svc */

/* the serve loop runs the programming session — the 0x29 and image Ed25519 verifies, the deepest
 * frames in the boot — so it gets the stack the bare-metal boot's main loop had room for */
#define SERVE_STACK 16384

static TX_THREAD serve_thread;
static UCHAR serve_stack[SERVE_STACK] __attribute__((aligned(8)));
static TX_SEMAPHORE wake;

/* doip_netx.c wakes the thread that answers its mailbox after posting: the serve loop's rest */
void comm_wake(void) {
	tx_semaphore_ceiling_put(&wake, 1);
}

/* boot_net_rest: the serve loop's pause while nothing is in flight on the bus — a tick at most, so
 * the bus is still polled every millisecond, and over at once when a DoIP request is posted */
void boot_net_rest(void) {
	(void)tx_semaphore_get(&wake, 1);
}

static void serve_entry(ULONG arg) {
	(void)arg;
	/* NetX draws TCP initial sequence numbers from rand(): seed it from the TRNG before the doip
	 * thread opens its sockets (it waits for this), as the application's comm thread does */
	uint8_t b[4];
	unsigned int seed = 0u;
	if (diag_sa_init() && diag_sa_seed(b, 4)) {
		seed = (unsigned int)b[0] | ((unsigned int)b[1] << 8) | ((unsigned int)b[2] << 16) |
		       ((unsigned int)b[3] << 24);
	}
	doip_net_seed(seed);
	blobly_boot_serve();
}

void tx_application_define(void *first_unused) {
	(void)first_unused;
	tx_semaphore_create(&wake, "boot-wake", 0);
	blobly_boot_net_init(); /* ThreadX objects are made here, never before the kernel initialises */
	tx_thread_create(&serve_thread, "boot", serve_entry, 0, serve_stack, sizeof(serve_stack), SERVE_PRIO,
	                 SERVE_PRIO, TX_NO_TIME_SLICE, TX_AUTO_START);
	doip_net_timers(BOOT_DOIP_INITIAL_MS, BOOT_DOIP_GENERAL_MS);
	(void)doip_net_create(BOOT_DOIP_ADDR, IP_PRIO, NET_PRIO); /* -1: DoIP stays down, the bus serves on */
}

/* boot_net_start: hand the stay path to the kernel (never returns; tx_application_define above) */
void boot_net_start(void) {
	tx_kernel_enter();
}

/* ---- the entity's identity and policy, as the application's ([doip]) ---- */

static const uint8_t g_vin[17] = BOOT_DOIP_VIN;
static const uint16_t g_testers[] = BOOT_DOIP_TESTERS;
static const uint8_t g_act_types[] = BOOT_DOIP_ACT_TYPES;

uint16_t boot_doip_logical(void) { return BOOT_DOIP_LOGICAL; }
uint16_t boot_doip_functional(void) { return BOOT_DOIP_FUNCTIONAL; }
int boot_doip_announce_count(void) { return BOOT_DOIP_ANNOUNCE_COUNT; }
int boot_doip_announce_ms(void) { return BOOT_DOIP_ANNOUNCE_MS; }

void boot_doip_vin(uint8_t *out) {
	for (int i = 0; i < 17; i++) {
		out[i] = g_vin[i];
	}
}

/* the tester addresses that may activate routing (0 = any tester address) */
int boot_doip_testers(uint16_t *out) {
	for (int i = 0; i < BOOT_DOIP_N_TESTERS; i++) {
		out[i] = g_testers[i];
	}
	return BOOT_DOIP_N_TESTERS;
}

/* the activation types served (0 = type 0x00 only) */
int boot_doip_act_types(uint8_t *out) {
	for (int i = 0; i < BOOT_DOIP_N_ACT_TYPES; i++) {
		out[i] = g_act_types[i];
	}
	return BOOT_DOIP_N_ACT_TYPES;
}
