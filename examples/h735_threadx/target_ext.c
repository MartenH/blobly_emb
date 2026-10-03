/* h735_threadx target extensions: the shell's own target command, `boot` (the built-in
 * ps/bmc are boards/common/shell_glue.c).
 *
 * The generic glue every generated image links — the IOC pool, the load cells, the FDCAN Rx
 * ISR and the comm-thread wake semaphore — is boards/common/comm_glue.c, listed by
 * gen/loom_build.mk (LOOM_GLUE_SRCS). This file adds only what is this image's own, and
 * defines nothing that one does.
 */
#include "tx_api.h"
#include <stm32h7xx.h>
#include "bootmap.h" /* the boot manager <-> app contract (docs/bootloader.md) */

/* shell_boot — the `boot` command ([shell] commands=["boot"]): write the SRAM4
 * request cell and reset into the boot manager (the app->boot rung, REQ-BOOT-003).
 * Without it, a running valid H735 image can only be reflashed over CAN via an
 * external reset/debugger — the debugger-free update loop needs this half. The
 * response never leaves the board: the reset preempts the ISO-TP exchange,
 * 0x11-style — NO reply IS the ack; the tester's next move is a UDS session to
 * the boot ids. SRAM4 (D3) is already accessible (the trace ring lives there). */
int shell_boot(unsigned char *out, int cap)
{
    (void)out;
    (void)cap;
    volatile uint32_t *cell = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
    cell[1] = 1u; /* arg first: the magic makes the pair valid, so it lands last */
    cell[0] = BOOTCELL_REQ_MAGIC;
    __asm__ volatile("dsb");
    NVIC_SystemReset();
    return 0; /* unreachable */
}
