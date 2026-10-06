/* LVGL attribute overrides for the H735-DK display (lv_conf.h LV_ATTRIBUTE_CUSTOM_INCLUDE): LVGL's
 * pool goes to the AXI SRAM (.axisram, boards/h735dk/threadx.ld), out of the real-time DTCM. */
#ifndef BOARD_LV_ATTR_H
#define BOARD_LV_ATTR_H
#define LV_ATTRIBUTE_LARGE_RAM_ARRAY __attribute__((section(".axisram"), aligned(8)))
#endif
