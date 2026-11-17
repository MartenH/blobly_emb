/* diag_io_ok.h — the default of the board's InputOutputControlByIdentifier conditions seam
 * (0x2F, docs/diagnostics.md §3.1 "Input/output control"), included by diag_board.c. Portable C,
 * apart from diag_board.c's register code, so a host test runs the very default a target links
 * (tools/loom2v/io_control_test.v).
 *
 * diag_io_ok: 1 = the control may be taken, 0 = conditionsNotCorrect (0x22), nothing changed.
 * `did` is the controlled DID, `param` the control parameter (1 resetToDefault, 2
 * freezeCurrentState, 3 shortTermAdjustment; never asked for 0 returnControlToECU). WEAK and
 * accepting: a node states its conditions (the vehicle moving, say) by defining it in its glue. */
#ifndef DIAG_IO_OK_H
#define DIAG_IO_OK_H

#include <stdint.h>

__attribute__((weak)) int diag_io_ok(uint16_t did, uint8_t param) {
	(void)did;
	(void)param;
	return 1;
}

#endif
