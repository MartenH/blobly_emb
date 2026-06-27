/* CAN driver-port backend selector.
 *
 * The V side compiles this single translation unit (#flag .../can_backend.c);
 * it pulls in exactly ONE backend, chosen by a -D macro. With no macro (the
 * host/sim build) it is plain SocketCAN over vcan, so the examples and the
 * blobly_net integration tests are unaffected. The target backends are only
 * compiled when their macro is set (and their SDK headers are on the include
 * path), so they never break the host build.
 *
 *   v ... run examples/<x>                       -> SocketCAN (vcan)
 *   v -cflags '-DBLOB_CAN_FDCAN -I<CMSIS inc>'    -> STM32 H7 FDCAN, register-level (no HAL)
 *   v -cflags '-DBLOB_CAN_STHAL -I<ST HAL inc>'   -> STM32 H7 FDCAN over the ST HAL
 *   v -cflags '-DBLOB_CAN_CANIF -I<BSW inc>'      -> AUTOSAR CanIf (CDD)
 */
#if defined(BLOB_CAN_FDCAN)
#  include "can_fdcan.c"   /* STM32 H7 FDCAN — bare-metal M_CAN registers (CMSIS, no HAL) */
#elif defined(BLOB_CAN_STHAL)
#  include "can_sthal.c"   /* STM32 H7 FDCAN over the ST HAL (only if you're already on Cube) */
#elif defined(BLOB_CAN_CANIF)
#  include "can_canif.c"   /* AUTOSAR: plug in above CanIf as a CDD / CanIf user */
#else
#  include "can_socket.c"  /* host / sim: Linux SocketCAN (vcan) */
#endif
