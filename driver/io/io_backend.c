/* IO driver-port backend selector.
 *
 * The V side compiles this single translation unit (#flag .../io_backend.c);
 * it pulls in exactly ONE backend, chosen by a -D macro. With no macro (the
 * host/sim build) it is the file mirror under io/<name>, so examples and
 * tests run with zero target hardware. The target backend is only compiled
 * when its macro is set, so it never breaks the host build.
 *
 *   v ... run examples/<x>              -> file mirror (io/<name>)
 *   v -cflags '-DBLOB_IO_STM32 ...'     -> STM32 GPIO via the board pin table
 */
#if defined(BLOB_IO_STM32)
#  include "io_stm32.c"  /* STM32 H7 GPIO — register-level (CMSIS, no HAL) */
#else
#  include "io_file.c"   /* host / sim: file mirror, io/<name> under cwd */
#endif
