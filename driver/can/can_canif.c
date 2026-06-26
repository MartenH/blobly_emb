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

int blob_can_open(const char *name, int fd_mode) {
	(void)fd_mode; /* classic/FD is fixed by the L-PDU's CanIf config */
	int idx = (name && name[0]) ? atoi(name) : 0;
	if (idx < 0 || idx >= BLOB_CAN_BUSES) return -1;
	CanIf_SetControllerMode(bus_controller[idx], CANIF_CS_STARTED);
	return idx;
}

int blob_can_send(int h, uint32_t id, const uint8_t *data, uint8_t len, int fd_mode) {
	(void)fd_mode;
	for (int i = 0; i < tx_map_n; i++) {
		if (tx_map[i].bus == h && tx_map[i].id == id) {
			PduInfoType pdu;
			pdu.SduDataPtr  = (uint8_t *)data;
			pdu.SduLength   = len;
			pdu.MetaDataPtr = 0; /* set for dynamic-id Tx PDUs (id carried in MetaData) */
			return CanIf_Transmit(tx_map[i].pdu, &pdu) == E_OK ? 0 : -1;
		}
	}
	return -1; /* (bus,id) not in the CanIf Tx config */
}

int blob_can_recv(int h, uint32_t *id, uint8_t *data, uint8_t *len) {
	if (h < 0 || h >= BLOB_CAN_BUSES) return -1;
	return blob_ring_pop(&rx_ring[h], id, data, len);
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
			blob_ring_push(&rx_ring[rx_map[i].bus], rx_map[i].id,
			               PduInfoPtr->SduDataPtr, (uint8_t)PduInfoPtr->SduLength);
			return;
		}
	}
}
