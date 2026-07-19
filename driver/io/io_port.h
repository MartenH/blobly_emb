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

/* kind: 0 = gpio (bool level), 1 = adc (analog input, u32 count), 2 = pwm
 * (analog output, u32 permille). `param` is the pwm carrier freq_hz; unused
 * for gpio/adc. ADC points free-run (continuous scan + circular DMA) from
 * blob_io_init(); the io thread only reads (REQ-IO-018). */
int  blob_io_cfg(int ch, const char *name, const char *pin, int dir, unsigned int init_val, int active_low, int kind, unsigned int param); /* declare one point before init; dir 0=in 1=out; init + all reads/writes are LOGICAL, active_low inverts at the pad (REQ-IO-017); 0=ok */
int  blob_io_init(void);                    /* apply output init levels FIRST (before any app runs), start ADC scan/DMA, open the backend; 0=ok */
int  blob_io_gpio_read(int ch);             /* current level 0/1; on backend failure returns the last good value (never blocks) */
int  blob_io_gpio_read_checked(int ch, int *val); /* 0 = real value in *val, -1 = unreadable/unparsable — NO last-good fallback (boot must not fabricate a sample) */
void blob_io_gpio_write(int ch, int level); /* drive an output point */
unsigned int blob_io_adc_read(int ch);      /* latest converter count — one atomic load from the DMA array (never blocks, REQ-IO-018) */
int  blob_io_adc_read_checked(int ch, unsigned int *val); /* 0 = a REAL conversion in *val, -1 = none yet — boot must not fabricate (like gpio_read_checked) */
void blob_io_pwm_write(int ch, unsigned int permille); /* set PWM duty 0..1000 (clamped above); a compare-register update */
void blob_io_close(void);

#endif
