#include "can_port.h"
#include "can_ring.h"
#include "CanIf.h"             /* CanIf_Transmit, CanIf_SetControllerMode */
#include "Can_GeneralTypes.h"  /* PduInfoType, PduIdType, Std_ReturnType, E_OK */
#include <stdlib.h>            /* atoi (init only) */

/* AUTOSAR backend: blobly plugs in ABOVE CanIf as a CDD / CanIf user, so on a
 * vendor BSW (Vector, EB, ...) we do NOT own the Can driver/MCAL — CanIf does.
 *
 *   TX:  blob_can_send  -> CanIf_Transmit(TxPduId, PduInfo)
 *   RX:  CanIf calls Blobly_RxIndication(RxPduId, PduInfo)  [configure the Rx
 *        PDU's upper layer = this CDD]; we push into a per-bus SPSC ring that
 *        the bridge drains on its tick via blob_can_recv — so application code
 *        never runs in CanIf/ISR context (same ISR<->task boundary as the IOC).
 *
 * The (bus,id) <-> PduId mapping is STATIC AUTOSAR config: CanIf_Transmit takes
 * a PduId, not a CAN id, and a received PDU arrives as an RxPduId. So we keep
 * two small tables that the System/integration team fills from the ECU extract
 * (the CanIf Tx/Rx PDU config). These are the only thing that changes per ECU;
 * everything above stays the generated, platform-independent blobly stack. */

#ifndef BLOB_CAN_BUSES
#define BLOB_CAN_BUSES 2
#endif

typedef struct { int bus; uint32_t id; PduIdType pdu; } tx_map_t;
typedef struct { PduIdType pdu; int bus; uint32_t id; } rx_map_t;

/* ---- INTEGRATION TABLES — fill from the AUTOSAR ECU extract (placeholders) ---- */
static const uint8_t bus_controller[BLOB_CAN_BUSES] = { 0, 1 };   /* CanIf ControllerId per bus */

static const tx_map_t tx_map[] = {
	/* { bus, can_id, CanIfTxPduId } — one row per tx frame. Example: */
	{ 0, 0x101u, 0 },
};
static const rx_map_t rx_map[] = {
	/* { CanIfRxPduId, bus, can_id } — one row per rx frame routed to this CDD. Example: */
	{ 0, 0, 0x100u },
};
static const int tx_map_n = (int)(sizeof(tx_map) / sizeof(tx_map[0]));
static const int rx_map_n = (int)(sizeof(rx_map) / sizeof(rx_map[0]));

static blob_can_ring rx_ring[BLOB_CAN_BUSES];
/* Frames dropped because the Rx SPSC ring was full. Written in Blobly_RxIndication (CanIf/
 * ISR context), read by the bridge/telemetry task via blob_can_rx_overruns — volatile so
 * the single-writer count isn't cached/reordered across that boundary (an aligned u32
 * load/store is atomic on the M-profile targets, and the ISR is the only writer). */
static volatile uint32_t rx_lost[BLOB_CAN_BUSES];

int blob_can_open(const char *name, int fd_mode) {
	(void)fd_mode; /* classic/FD is fixed by the L-PDU's CanIf config */
	if (!name || !name[0])
		return -1;
	/* Take the trailing decimal suffix as the bus index ("vcan1" -> 1, "can0" -> 0,
	 * "2" -> 2). Reject a name with no numeric suffix rather than parsing it as 0:
	 * atoi("vcan1") == 0 would have aliased both logical channels onto bus 0. */
	int len = 0;
	while (name[len])
		len++;
	int start = len;
	while (start > 0 && name[start - 1] >= '0' && name[start - 1] <= '9')
		start--;
	if (start == len)
		return -1; /* no numeric suffix */
	int idx = 0;
	for (int i = start; i < len; i++)
		idx = idx * 10 + (name[i] - '0');
	if (idx < 0 || idx >= BLOB_CAN_BUSES)
		return -1;
	rx_lost[idx] = 0; /* fresh session: clear a prior controller run's ring-drop tally */
	CanIf_SetControllerMode(bus_controller[idx], CANIF_CS_STARTED);
	return idx;
}

/* In-flight PDUs per bus: CanIf_Transmit acceptance only means "buffered" — the
 * frame is on the wire when CanIf calls TxConfirmation. blob_can_send increments,
 * Blobly_TxConfirmation decrements, tx_idle is pending == 0 (REQ-BOOT-012: a
 * self-resetting node must not reset its response away). Route the Tx PDUs'
 * upper-layer confirmation to this CDD, same as the Rx indication. If the
 * integration does NOT wire it, pending never drains and tx_idle stays 0 — the
 * caller's bounded wait then rules (fail-slow, never lose-the-ack). */
static volatile uint32_t tx_pending[BLOB_CAN_BUSES];

void Blobly_TxConfirmation(PduIdType pdu) {
	for (int i = 0; i < tx_map_n; i++) {
		if (tx_map[i].pdu == pdu) {
			int b = tx_map[i].bus;
			if (b >= 0 && b < BLOB_CAN_BUSES)
				__atomic_fetch_sub(&tx_pending[b], 1u, __ATOMIC_SEQ_CST);
			return;
		}
	}
}

int blob_can_send(int h, uint32_t id, const uint8_t *data, uint8_t len, int flags) {
	(void)flags; /* AUTOSAR: the frame format (id width, FD) is owned by the CanIf/Can config, not set here */
	for (int i = 0; i < tx_map_n; i++) {
		if (tx_map[i].bus == h && tx_map[i].id == id) {
			PduInfoType pdu;
			pdu.SduDataPtr  = (uint8_t *)data;
			pdu.SduLength   = len;
			pdu.MetaDataPtr = 0; /* set for dynamic-id Tx PDUs (id carried in MetaData) */
			if (h >= 0 && h < BLOB_CAN_BUSES) /* atomics: confirmation runs in CanIf/ISR context */
				__atomic_fetch_add(&tx_pending[h], 1u, __ATOMIC_SEQ_CST);
			if (CanIf_Transmit(tx_map[i].pdu, &pdu) == E_OK)
				return 0;
			if (h >= 0 && h < BLOB_CAN_BUSES)
				__atomic_fetch_sub(&tx_pending[h], 1u, __ATOMIC_SEQ_CST); /* rejected: undo */
			return -1;
		}
	}
	return -1; /* (bus,id) not in the CanIf Tx config */
}

/* CanIf owns its own Tx buffering/queueing, so report ready and let CanIf_Transmit
 * absorb bursts (size the CanIf Tx buffers for the integrator's worst case). */
int blob_can_tx_ready(int h) {
	(void)h;
	return 1;
}

/* Wire-done via the TxConfirmation tally above (REQ-BOOT-012). */
int blob_can_tx_idle(int h) {
	if (h < 0 || h >= BLOB_CAN_BUSES)
		return 1;
	return __atomic_load_n(&tx_pending[h], __ATOMIC_SEQ_CST) == 0u;
}

int blob_can_recv(int h, uint32_t *id, uint8_t *data, uint8_t *len, int *flags) {
	if (h < 0 || h >= BLOB_CAN_BUSES) return -1;
	*flags = 0; /* the Rx ring carries id/data/len; per-frame format flags via CanIf are a follow-up */
	return blob_ring_pop(&rx_ring[h], id, data, len);
}

/* Rx-overrun events for this bus: frames CanIf delivered that the CDD had to drop because
 * the Rx SPSC ring was full (the loss that happens in this shim, below the BSW's own Det/
 * Dem diagnostics). REQ-CAN-DRV-008. */
uint32_t blob_can_rx_overruns(int h) {
	return (h >= 0 && h < BLOB_CAN_BUSES) ? rx_lost[h] : 0u;
}

void blob_can_close(int h) {
	if (h >= 0 && h < BLOB_CAN_BUSES)
		CanIf_SetControllerMode(bus_controller[h], CANIF_CS_STOPPED);
}

/* Wire this as the Rx PDU's user RxIndication in the CanIf config (UL = CDD).
 * Runs in CanIf/ISR context: it only enqueues — no decode, no app code. */
void Blobly_RxIndication(PduIdType RxPduId, const PduInfoType *PduInfoPtr) {
	for (int i = 0; i < rx_map_n; i++) {
		if (rx_map[i].pdu == RxPduId) {
			/* The SPSC ring is the ISR->task boundary; if the bridge hasn't drained it and
			 * it is full, the frame is lost HERE (below CanIf's own diagnostics), so count
			 * it — receive-with-loss must be observable, not silent (REQ-CAN-DRV-008). */
			if (blob_ring_push(&rx_ring[rx_map[i].bus], rx_map[i].id, PduInfoPtr->SduDataPtr,
			                   (uint8_t)PduInfoPtr->SduLength) != 0)
				rx_lost[rx_map[i].bus]++;
			return;
		}
	}
}
