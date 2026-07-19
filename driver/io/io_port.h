#ifndef BLOBLY_IO_PORT_H
#define BLOBLY_IO_PORT_H

/* IO driver PORT — the narrow contract the generated io glue depends on.
 *
 * The V side (driver/io/io.v) calls exactly these functions; each platform
 * provides ONE implementation, selected at build time in io_backend.c:
 *
 *   (default)          host / sim    file mirror io/<name>    (io_file.c)
 *   -DBLOB_IO_STM32    STM32 target  board pin table          (bench phase)
 *
 * Channels are indexes assigned by the generator (0..N-1); each is declared
 * once via blob_io_cfg() BEFORE blob_io_init(). `pin` is the board pin name
 * ("PB0") — informational on the host backend, the pin-table key on target.
 * All state is static fixed-size tables — no heap, ever.
 *
 * blob_io_init() applies every output's init level FIRST, before any
 * application code runs (REQ-IO-009): no reset-to-thread window where a
 * floating pin feeds an active-high actuator. The io thread starts later
 * and only ever re-applies.
 *
 * Reads are WAIT-FREE by contract (REQ-IO-008): blob_io_gpio_read() does a
 * bounded amount of work and returns — no syscall result may make it block
 * or retry unboundedly. On backend failure it returns the point's LAST-GOOD
 * value (the latest-complete-sample rule, REQ-IO-003), never an error the
 * app must handle mid-loop. */

int  blob_io_cfg(int ch, const char *name, const char *pin, int dir, unsigned int init_val); /* declare one point before init; dir: 0=in 1=out; 0=ok */
int  blob_io_init(void);                    /* apply output init levels FIRST (before any app runs), open the backend; 0=ok */
int  blob_io_gpio_read(int ch);             /* current level 0/1; on backend failure returns the last good value (never blocks) */
int  blob_io_gpio_read_checked(int ch, int *val); /* 0 = real value in *val, -1 = unreadable/unparsable — NO last-good fallback (boot must not fabricate a sample) */
void blob_io_gpio_write(int ch, int level); /* drive an output point */
void blob_io_close(void);

#endif
