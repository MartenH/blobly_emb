/* Host-test stand-in for a generated xcore_gen.h (tools/xioc/xcore_down_test.v): a layout id, and
 * the owner-written window and the busy slots placed in ordinary arrays. The test includes it ahead of
 * xcore_owner.c / xcore_sat.c so xcore.h sees the overridden base. */
#ifndef XCORE_DOWN_TEST_GEN_H
#define XCORE_DOWN_TEST_GEN_H
#include <stdint.h>
#define XCORE_LAYOUT_ID 0x1234ABCDu
static uint32_t xcore_test_ow[1024] __attribute__((aligned(32)));
#define XCORE_OW_BASE ((uintptr_t)xcore_test_ow)
static inline uint32_t *xcore_test_sram(void) { return xcore_test_ow; }
/* the busy slots (xcore.h XCORE_BUSY_ADDR), likewise */
static uint32_t xcore_test_busy[8];
#define XCORE_BUSY_ADDR ((uintptr_t)xcore_test_busy)
static inline uint32_t *xcore_test_busy_slots(void) { return xcore_test_busy; }
#endif
