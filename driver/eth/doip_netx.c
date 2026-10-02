/* driver/eth/doip_netx.c — DoIP's transport on a ThreadX + NetX node whose diagnostic server lives
 * on the CAN comm thread (loom2v `[doip]`, docs/diagnostics.md). Sockets and threads only: DoIP
 * framing is comm/doip and the UDS server is comm/diag, both tested V.
 *
 *   doip_net_create  — from tx_application_define: NetX through the shared bring-up (netx_up.c, at
 *                      the node's one address — SOME/IP may be on it too), TCP, and two threads.
 *                      `doip` waits for the TCP sequence-number seed, then for the PHY link, opens
 *                      UDP 13400 (announcements, identification) and the TCP 13400 listener, and
 *                      runs the generated V loop (blobly_doip_run); `doip-svc` polls the link and
 *                      answers the UDP requests (identification, entity status, power mode).
 *   doip_net_timers  — before doip_net_create: the ISO 13400 inactivity limits ([doip]).
 *   doip_net_seed    — from the comm thread, once it has the TRNG: NetX draws TCP initial sequence
 *                      numbers from rand(), and predictable ones make a session spoofable.
 *   doip_stream_*    — the TCP byte pipe the V loop drives (one tester at a time, ISO 13400 idle
 *                      limits), doip_udp_broadcast / doip_eid / doip_sleep_ms beside it.
 *   doip_mb_*        — the mailbox that carries one request to the comm thread and its answer back:
 *                      the server has ONE owner thread. The doip thread posts and waits; the comm
 *                      thread serves it at the top of its next pass, woken (comm_wake). One mutex
 *                      covers the buffers; the comm thread only ever tries it, so it never blocks on
 *                      the network. Sequence numbers keep a late answer from being read as the next.
 *
 * All memory static (REQ-NET-001/002). */
#include "tx_api.h"
#include "nx_api.h"
#include "netx_up.h"

#define DOIP_PORT  13400
#define IDENT_PER_PASS 4 /* identification requests answered per 200 ms service pass */
#define TCP_WINDOW 2048

static UCHAR doip_thread_stack[4096] __attribute__((aligned(8))); /* runs the V loop */
static UCHAR svc_thread_stack[2048] __attribute__((aligned(8)));

static TX_THREAD doip_thread;
static TX_THREAD svc_thread;
static NX_TCP_SOCKET tcp_sock;
static NX_UDP_SOCKET udp_sock;
static volatile UINT sockets_up;

/* bench-observable (SWD) */
volatile ULONG doip_rx_bytes;
volatile ULONG doip_tx_bytes;
volatile ULONG doip_mb_timeouts;
volatile ULONG doip_setup_failed; /* the sockets could not be made: DoIP is down */

extern void blobly_doip_run(void);                                          /* generated V loop */
extern int blobly_doip_udp(const unsigned char *req, int len, unsigned char *resp); /* generated */
extern void comm_wake(void);                                                /* comm_glue.c */

void doip_net_seed(unsigned int seed) {
	blob_net_seed(seed);
}

/* ---- the mailbox to the comm thread ------------------------------------------------------- */

/* the doip thread waits this long for the comm thread (which answers within a pass); a request
 * not taken by then is WITHDRAWN, so it is never served after its tester was told it failed */
#define MB_TIMEOUT_MS 2000u

static TX_MUTEX mb_mutex;
static TX_SEMAPHORE mb_done;   /* put by each answer; a stale put is told apart by sequence */
static unsigned char *mb_req;  /* the generated globals, sized by the V constants */
static unsigned char *mb_resp;
static int mb_req_len;
static int mb_functional;
static int mb_resp_len;
static ULONG mb_posted;        /* sequence of the request posted */
static ULONG mb_answered;      /* sequence of the request answered */
static ULONG mb_returned;      /* the doip thread: the last answer handed to the V loop */
/* what the doip thread reports, by SEQUENCE, so a report about an earlier answer or connection is
 * never read as one about the request the comm thread answered last */
static volatile ULONG mb_sent_seq;   /* the last answer handed to TCP */
static volatile ULONG mb_drops;      /* connections dropped */
static volatile ULONG mb_drop_after; /* the request posted last when the latest one dropped */
static ULONG mb_sent_seen;           /* the comm thread's last reading of each */
static ULONG mb_drops_seen;

void doip_mb_init(unsigned char *req_buf, unsigned char *resp_buf) {
	mb_req = req_buf;
	mb_resp = resp_buf;
	tx_mutex_create(&mb_mutex, "doip-mb", TX_INHERIT);
	tx_semaphore_create(&mb_done, "doip-mb-done", 0);
}

/* doip thread: post one request and wait for its answer; the answer's length, or -1 when the comm
 * thread did not answer in time (comm/doip NACKs it). */
int doip_mb_call(const unsigned char *req, int len, int functional, unsigned char *resp, int cap) {
	tx_mutex_get(&mb_mutex, TX_WAIT_FOREVER);
	for (int i = 0; i < len; i++) {
		mb_req[i] = req[i];
	}
	mb_req_len = len;
	mb_functional = functional;
	ULONG seq = ++mb_posted;
	tx_mutex_put(&mb_mutex);
	comm_wake();
	ULONG deadline = tx_time_get() + MS_TICKS(MB_TIMEOUT_MS);
	for (;;) {
		ULONG left = deadline - tx_time_get();
		UINT got = (left == 0u || left > MS_TICKS(MB_TIMEOUT_MS))
			? TX_NO_INSTANCE : tx_semaphore_get(&mb_done, left);
		tx_mutex_get(&mb_mutex, TX_WAIT_FOREVER);
		if (mb_answered == seq) {
			int n = mb_resp_len;
			if (n > cap) {
				n = -1;
			}
			for (int i = 0; i < n; i++) {
				resp[i] = mb_resp[i];
			}
			mb_returned = seq;
			tx_mutex_put(&mb_mutex);
			return n;
		}
		if (got != TX_SUCCESS) {
			/* not taken in time: withdraw it — the comm thread is not serving it (it would hold
			 * the mutex), so marking it answered is all it takes */
			mb_answered = seq;
			mb_resp_len = -1;
			tx_mutex_put(&mb_mutex);
			doip_mb_timeouts++;
			return -1;
		}
		tx_mutex_put(&mb_mutex); /* a stale put from an earlier answer: wait on */
	}
}

/* comm thread: the length of a request waiting to be served, with the mailbox now HELD until
 * doip_mb_answer; -1 = none waiting, or the doip thread is mid-copy (next pass). */
int doip_mb_take(int *functional) {
	if (mb_req == NX_NULL || tx_mutex_get(&mb_mutex, TX_NO_WAIT) != TX_SUCCESS) {
		return -1;
	}
	if (mb_answered == mb_posted) {
		tx_mutex_put(&mb_mutex);
		return -1;
	}
	*functional = mb_functional;
	return mb_req_len;
}

/* comm thread: the answer to the request doip_mb_take returned (written to the response buffer).
 * Releases the mailbox. */
void doip_mb_answer(int n) {
	mb_resp_len = n;
	mb_answered = mb_posted;
	tx_mutex_put(&mb_mutex);
	tx_semaphore_put(&mb_done);
}

/* comm thread: 1 once the answer it gave last has been handed to TCP */
int doip_mb_take_sent(void) {
	ULONG s = mb_sent_seq;
	int r = s == mb_answered && s != mb_sent_seen;
	mb_sent_seen = s;
	return r;
}

/* comm thread: 1 once a connection has dropped that the request it answered last came over — a
 * drop older than that request belongs to a tester whose state is already superseded */
int doip_mb_take_dropped(void) {
	ULONG d = mb_drops;
	int r = d != mb_drops_seen && mb_drop_after >= mb_answered;
	mb_drops_seen = d;
	return r;
}

/* ---- the TCP byte pipe -------------------------------------------------------------------- */

static volatile UINT tcp_connected; /* read by the svc and comm threads too */
static NX_PACKET *rx_pending; /* partially consumed receive (packet > caller's buf) */
static ULONG rx_pending_off;
static ULONG rx_idle_ticks;   /* ticks since the peer last sent anything */
static UINT sess_activated;   /* V-side routing activation state (selects the idle limit) */
static ULONG conn_start;      /* tick of accept: the pre-activation deadline base */

/* ISO 13400 inactivity: T_TCP_Initial_Inactivity (default 2 s: a connection that never activates
 * routing must not hold the one server socket — measured from ACCEPT, so trickled bytes don't
 * extend it), T_TCP_General_Inactivity (default 5 min idle after activation). Set from [doip] by
 * doip_net_timers before the threads exist; comm/doip policy.v bounds them, so MS_TICKS stays in
 * 32 bits. */
static ULONG idle_initial = 2u * NX_IP_PERIODIC_RATE;
static ULONG idle_general = 300u * NX_IP_PERIODIC_RATE;

void doip_net_timers(unsigned int initial_ms, unsigned int general_ms) {
	idle_initial = MS_TICKS(initial_ms);
	idle_general = MS_TICKS(general_ms);
}

/* drop the connection and return the socket to listening; the comm thread hears of it */
static int stream_recycle(void) {
	if (rx_pending) {
		nx_packet_release(rx_pending);
		rx_pending = NX_NULL;
	}
	nx_tcp_socket_disconnect(&tcp_sock, NX_IP_PERIODIC_RATE);
	nx_tcp_server_socket_unaccept(&tcp_sock);
	nx_tcp_server_socket_relisten(blob_net_ip(), DOIP_PORT, &tcp_sock);
	tcp_connected = 0;
	mb_drop_after = mb_posted;
	mb_drops++;
	comm_wake();
	return -1;
}

/* one call = accept-if-needed + one bounded receive. >0 = bytes copied; 0 = idle; -1 = the
 * connection dropped (socket back to listening; the V side resets its DoIP state).
 *
 * accept MUST wait forever: a timed-out NetX accept returns the socket to LISTEN without clearing
 * bound_next, and the next accept sends a SYN-ACK to a null address and trips an NX_ASSERT that
 * wedges the IP thread (bench-paid on examples/h735_doip). timeout_ticks bounds the receive. */
int doip_stream_recv(unsigned char *buf, int max, unsigned int timeout_ticks) {
	if (!tcp_connected) {
		if (nx_tcp_server_socket_accept(&tcp_sock, NX_WAIT_FOREVER) != NX_SUCCESS) {
			return 0;
		}
		tcp_connected = 1;
		rx_idle_ticks = 0;
		conn_start = tx_time_get();
	}
	/* the pre-activation deadline is ABSOLUTE from accept */
	if (!sess_activated && (tx_time_get() - conn_start) >= idle_initial) {
		return stream_recycle();
	}
	if (!rx_pending) {
		UINT s = nx_tcp_socket_receive(&tcp_sock, &rx_pending, timeout_ticks);
		if (s != NX_SUCCESS) {
			rx_pending = NX_NULL;
			if (s == NX_NO_PACKET) {
				rx_idle_ticks += timeout_ticks;
				return (sess_activated && rx_idle_ticks >= idle_general) ? stream_recycle() : 0;
			}
			return stream_recycle(); /* peer closed, or an error */
		}
		rx_pending_off = 0;
	}
	/* a packet larger than the caller's buffer is kept and continued next call */
	ULONG got = 0;
	nx_packet_data_extract_offset(rx_pending, rx_pending_off, buf, (ULONG)max, &got);
	rx_pending_off += got;
	if (rx_pending_off >= rx_pending->nx_packet_length) {
		nx_packet_release(rx_pending);
		rx_pending = NX_NULL;
	}
	rx_idle_ticks = 0;
	doip_rx_bytes += got;
	return (int)got;
}

/* the TCP_DATA sockets open now (0 or 1), for entity status asked over UDP — read from the svc
 * thread, a word the doip thread writes */
int doip_stream_open(void) {
	return tcp_connected ? 1 : 0;
}

/* doip_tx_pending: answer bytes handed to TCP that the tester has not acknowledged yet — the comm
 * thread waits for none before it resets the MCU (bounded there), as it waits for the CAN
 * controller's Tx FIFO: bytes in the transmit queue would die with the MCU */
int doip_tx_pending(void) {
	return tcp_connected && tcp_sock.nx_tcp_socket_transmit_sent_count != 0u;
}

/* a failed send recycles the connection (feed already consumed the request, so the answer is
 * unrecoverable — a half-served tester must reconnect, not wait); the V side resets on -1. A send
 * that carried an answer reports it to the comm thread (a reset may be waiting on it). */
int doip_stream_send(const unsigned char *buf, int len) {
	NX_PACKET *p = NX_NULL;
	if (nx_packet_allocate(blob_net_pool(), &p, NX_TCP_PACKET, NX_IP_PERIODIC_RATE) != NX_SUCCESS) {
		return stream_recycle();
	}
	if (nx_packet_data_append(p, (void *)buf, (ULONG)len, blob_net_pool(), NX_IP_PERIODIC_RATE) != NX_SUCCESS ||
	    nx_tcp_socket_send(&tcp_sock, p, NX_IP_PERIODIC_RATE) != NX_SUCCESS) {
		nx_packet_release(p); /* send takes ownership only on success */
		return stream_recycle();
	}
	doip_tx_bytes += (ULONG)len;
	mb_sent_seq = mb_returned;
	comm_wake();
	return len;
}

/* V-side fatal framing error: NACK already sent, drop the connection */
void doip_stream_drop(void) {
	if (tcp_connected) {
		(void)stream_recycle();
	}
}

void doip_stream_notify_activated(int on) {
	if (on && !sess_activated) {
		rx_idle_ticks = 0; /* the general-inactivity clock starts at activation */
	}
	sess_activated = (UINT)on;
}

void doip_udp_broadcast(const unsigned char *buf, int len) {
	NX_PACKET *p = NX_NULL;
	if (nx_packet_allocate(blob_net_pool(), &p, NX_UDP_PACKET, NX_NO_WAIT) != NX_SUCCESS) {
		return;
	}
	if (nx_packet_data_append(p, (void *)buf, (ULONG)len, blob_net_pool(), NX_NO_WAIT) != NX_SUCCESS ||
	    nx_udp_socket_send(&udp_sock, p, blob_net_addr() | 0xFFu, DOIP_PORT) != NX_SUCCESS) {
		nx_packet_release(p);
	}
}

/* paces the V side's boot announcements (ISO 13400 announce interval) */
void doip_sleep_ms(int ms) {
	tx_thread_sleep(MS_TICKS(ms));
}

/* the entity id: the interface MAC */
void doip_eid(unsigned char eid[6]) {
	NX_IP *ip = blob_net_ip();
	ULONG msw = ip->nx_ip_interface[0].nx_interface_physical_address_msw;
	ULONG lsw = ip->nx_ip_interface[0].nx_interface_physical_address_lsw;
	eid[0] = (unsigned char)(msw >> 8);
	eid[1] = (unsigned char)msw;
	eid[2] = (unsigned char)(lsw >> 24);
	eid[3] = (unsigned char)(lsw >> 16);
	eid[4] = (unsigned char)(lsw >> 8);
	eid[5] = (unsigned char)lsw;
}

/* ---- threads ------------------------------------------------------------------------------ */

/* the link poll (which also resyncs MACCR after renegotiation) and the UDP 13400 requests —
 * vehicle identification, entity status, power mode — the V loop parks in accept between
 * testers, so neither can live there */
static void svc_entry(ULONG arg) {
	(void)arg;
	while (!sockets_up) {
		tx_thread_sleep(NX_IP_PERIODIC_RATE / 10);
	}
	for (;;) {
		tx_thread_sleep(NX_IP_PERIODIC_RATE / 5); /* 200 ms */
		blob_net_poll_link();
		NX_PACKET *p;
		/* a bounded number per pass: a flood of requests must not keep this thread from its sleep,
		 * where the doip thread at the same priority runs (the rest wait, or the queue drops them) */
		for (int k = 0; k < IDENT_PER_PASS && nx_udp_socket_receive(&udp_sock, &p, NX_NO_WAIT) == NX_SUCCESS; k++) {
			unsigned char req[64], resp[64];
			ULONG got = 0, peer_ip = 0;
			UINT peer_port = 0;
			nx_udp_packet_info_extract(p, &peer_ip, NX_NULL, &peer_port, NX_NULL);
			nx_packet_data_extract_offset(p, 0, req, sizeof(req), &got);
			nx_packet_release(p);
			int n = blobly_doip_udp(req, (int)got, resp);
			if (n <= 0) {
				continue;
			}
			NX_PACKET *r = NX_NULL;
			if (nx_packet_allocate(blob_net_pool(), &r, NX_UDP_PACKET, NX_NO_WAIT) != NX_SUCCESS) {
				continue;
			}
			if (nx_packet_data_append(r, resp, (ULONG)n, blob_net_pool(), NX_NO_WAIT) != NX_SUCCESS ||
			    nx_udp_socket_send(&udp_sock, r, peer_ip, peer_port) != NX_SUCCESS) {
				nx_packet_release(r);
			}
		}
	}
}

static void doip_entry(ULONG arg) {
	(void)arg;
	while (!blob_net_seeded()) {
		tx_thread_sleep(NX_IP_PERIODIC_RATE / 100);
	}
	blob_net_wait_link();
	if (nx_udp_socket_create(blob_net_ip(), &udp_sock, "doip-udp", NX_IP_NORMAL, NX_DONT_FRAGMENT, 0x80, 5) != NX_SUCCESS ||
	    nx_udp_socket_bind(&udp_sock, DOIP_PORT, NX_WAIT_FOREVER) != NX_SUCCESS ||
	    nx_tcp_socket_create(blob_net_ip(), &tcp_sock, "doip-tcp", NX_IP_NORMAL, NX_DONT_FRAGMENT, 0x80,
	                         TCP_WINDOW, NX_NULL, NX_NULL) != NX_SUCCESS ||
	    nx_tcp_server_socket_listen(blob_net_ip(), DOIP_PORT, &tcp_sock, 1, NX_NULL) != NX_SUCCESS) {
		/* DoIP stays down: park rather than run the loop on a half-made socket (which would spin) */
		doip_setup_failed = 1;
		for (;;) {
			tx_thread_sleep(TX_TIMER_TICKS_PER_SECOND);
		}
	}
	sockets_up = 1;
	blobly_doip_run(); /* never returns */
}

/* doip_net_create: NetX and the two DoIP threads, from tx_application_define. ip_prio runs the
 * NetX IP thread, prio the doip and svc threads (below the comm thread that serves them).
 * 0 = done, -1 = a malformed address or a NetX failure (DoIP stays down; the node runs on). */
int doip_net_create(const char *addr, unsigned int ip_prio, unsigned int prio) {
	if (blob_net_up(addr, ip_prio) != 0) {
		return -1;
	}
	nx_tcp_enable(blob_net_ip()); /* only a DoIP image links the TCP engine */
	tx_thread_create(&doip_thread, "doip", doip_entry, 0, doip_thread_stack,
	                 sizeof(doip_thread_stack), prio, prio, TX_NO_TIME_SLICE, TX_AUTO_START);
	tx_thread_create(&svc_thread, "doip-svc", svc_entry, 0, svc_thread_stack,
	                 sizeof(svc_thread_stack), prio, prio, TX_NO_TIME_SLICE, TX_AUTO_START);
	return 0;
}

/* the threads this file runs, for the trace's deterministic ids (trace_bind_thread):
 * 0 = the NetX IP thread, 1 = doip, 2 = doip-svc */
void *doip_net_tcb(int i) {
	switch (i) {
	case 0: return &blob_net_ip()->nx_ip_thread;
	case 1: return &doip_thread;
	case 2: return &svc_thread;
	default: return NX_NULL;
	}
}
