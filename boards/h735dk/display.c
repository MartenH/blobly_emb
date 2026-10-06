/* The H735-DK display thread (display.h): LVGL, double buffered in the HyperRAM, touch polled.
 *
 * Both framebuffers are in the HyperRAM. LVGL draws (DIRECT mode) into the one not on screen; the
 * frame's last flush points the LTDC at it from the next vertical blanking, and LVGL is released
 * only once that switch has happened — then it copies the frame's dirty areas into the other
 * buffer itself. The wait sleeps, so it is not counted as the thread's CPU.
 *
 * The thread's own memory — its stack and LVGL's pool (lv_conf.h LV_ATTRIBUTE_LARGE_RAM_ARRAY) —
 * is in the AXI SRAM (.axisram): the DTCM belongs to the node's real-time threads.
 */
#include <stm32h735xx.h>
#include "tx_api.h"
#include "board.h"
#include "display.h"
#include "hyperram.h"
#include "lcd.h"
#include "touch.h"
#include "lvgl.h"

#define DISPLAY_STACK 16384u
#define FB_BYTES (LCD_W * LCD_H * 2u)

volatile int display_state;
volatile uint32_t display_load_pm, display_fps, display_cpu_pm;
volatile int display_touch_chip;

static TX_THREAD g_display;
static uint8_t g_display_stack[DISPLAY_STACK] __attribute__((section(".axisram"), aligned(8)));
static uint32_t g_flushes;
static uint64_t g_swap_wait;

/* The whole core's load, measured from below: an idle thread at the lowest priority (31) runs only
 * when no thread and no interrupt wants the CPU, and counts the cycles of its own loop steps. A
 * step longer than IDLE_STEP_MAX was preempted — that time was a thread's or an ISR's — and is not
 * counted. ThreadX's own idle loop spins on this port (no WFI), so the thread costs no power, and it
 * needs no kernel options. One writer (the idle thread); a 32-bit word the display thread reads,
 * differenced per second (the counter wraps in 7.8 s at 550 MHz). */
#define IDLE_STEP_MAX 256u
static TX_THREAD g_idle;
static uint8_t g_idle_stack[512] __attribute__((section(".axisram"), aligned(8)));
static volatile uint32_t g_idle_cycles;

static void idle_entry(ULONG arg) {
	(void)arg;
	uint32_t last = DWT->CYCCNT;
	for (;;) {
		uint32_t now = DWT->CYCCNT, d = now - last;
		last = now;
		if (d <= IDLE_STEP_MAX) g_idle_cycles += d;
	}
}

static uint32_t tick_ms(void) {
	return (uint32_t)(board_now_us() / 1000u);
}

static void flush_cb(lv_display_t *d, const lv_area_t *area, uint8_t *px) {
	(void)area;
	if (lv_display_flush_is_last(d)) {
		uint64_t t0 = board_now_us();
		lcd_show(px);
		while (!lcd_shown()) tx_thread_sleep(1);
		g_swap_wait += board_now_us() - t0;
		g_flushes++;
	}
	lv_display_flush_ready(d);
}

static void touch_cb(lv_indev_t *indev, lv_indev_data_t *data) {
	(void)indev;
	int x, y;
	data->state = touch_read(&x, &y) ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
	data->point.x = x;
	data->point.y = y;
}

static void display_entry(ULONG arg) {
	(void)arg;
	if (hyperram_init() != 0) {
		display_state = DISPLAY_NO_RAM; /* no framebuffers: leave the panel off, cost nothing */
		for (;;) tx_thread_sleep(TX_WAIT_FOREVER);
	}
	uint16_t *fb0 = (uint16_t *)HYPERRAM_BASE, *fb1 = (uint16_t *)(HYPERRAM_BASE + 0x40000u);
	for (uint32_t i = 0; i < LCD_W * LCD_H; i++) fb0[i] = fb1[i] = 0u;
	lcd_init(fb0);
	display_touch_chip = touch_init();

	lv_init();
	lv_tick_set_cb(tick_ms);
	lv_display_t *disp = lv_display_create(LCD_W, LCD_H);
	lv_display_set_buffers(disp, fb0, fb1, FB_BYTES, LV_DISPLAY_RENDER_MODE_DIRECT);
	lv_display_set_flush_cb(disp, flush_cb);
	lv_indev_t *ts = lv_indev_create();
	lv_indev_set_type(ts, LV_INDEV_TYPE_POINTER);
	lv_indev_set_read_cb(ts, touch_cb);
	ui_create();
	display_state = DISPLAY_RUNNING;

	uint64_t win_start = board_now_us(), busy = 0;
	uint32_t flushes0 = 0, idle0 = g_idle_cycles, cyc0 = DWT->CYCCNT;
	for (;;) {
		uint64_t t0 = board_now_us();
		ui_update();
		uint32_t wait = lv_timer_handler();
		uint64_t t1 = board_now_us();
		busy += t1 - t0;
		if (t1 - win_start >= 1000000u) {
			display_load_pm = (uint32_t)((busy - g_swap_wait) * 1000u / (t1 - win_start));
			display_fps = g_flushes - flushes0;
			uint32_t idle = g_idle_cycles, cyc = DWT->CYCCNT;
			uint32_t span = cyc - cyc0, idle_d = idle - idle0;
			display_cpu_pm = span ? 1000u - (uint32_t)((uint64_t)(idle_d > span ? span : idle_d) * 1000u / span) : 0u;
			idle0 = idle;
			cyc0 = cyc;
			flushes0 = g_flushes;
			busy = 0;
			g_swap_wait = 0;
			win_start = t1;
		}
		if (wait > 20u) wait = 20u; /* poll touch and the node's state at least at 50 Hz */
		tx_thread_sleep(wait ? wait : 1u);
	}
}

/* the pads this image's display owns, for board_io_pin_reserved (board.c): an io point on one
 * would silently take the LCD, the touch panel or the framebuffers away. Port 0=A..7=H. */
int board_display_pin(int port, int pin) {
	static const uint16_t owned[8] = {
		[0] = (1u << 3) | (1u << 4) | (1u << 6) | (1u << 8),                          /* PA: LCD */
		[1] = (1u << 0) | (1u << 1) | (1u << 8) | (1u << 9),                          /* PB: LCD */
		[2] = (1u << 6) | (1u << 7),                                                  /* PC: LCD */
		[3] = (1u << 0) | (1u << 3) | (1u << 6) | (1u << 10),                         /* PD: LCD, DISP_CTRL */
		[4] = (1u << 0) | (1u << 1) | (1u << 11) | (1u << 12) | (1u << 13) | (1u << 15), /* PE: LCD, DISP_EN */
		[5] = 0x000Fu | (1u << 4) | (1u << 12) | (1u << 14) | (1u << 15),            /* PF: HyperRAM, I2C4 */
		[6] = (1u << 0) | (1u << 1) | (1u << 7) | (1u << 10) | (1u << 11) | (1u << 12) | (1u << 14)
		    | (1u << 15),                                                             /* PG: HyperRAM, LCD, backlight */
		[7] = (1u << 3) | (1u << 4) | (1u << 8) | (1u << 9) | (1u << 10) | (1u << 11) | (1u << 15), /* PH: LCD */
	};
	return port >= 0 && port < 8 && pin >= 0 && pin < 16 && (owned[port] & (1u << pin)) != 0u;
}

void display_thread_create(unsigned int priority) {
	tx_thread_create(&g_display, "display", display_entry, 0, g_display_stack, sizeof g_display_stack, priority,
	                 priority, TX_NO_TIME_SLICE, TX_AUTO_START);
	/* priority 31 is the idle thread's: loom2v places the display at 30 at most (gen_display.v) */
	tx_thread_create(&g_idle, "idle", idle_entry, 0, g_idle_stack, sizeof g_idle_stack, 31u, 31u,
	                 TX_NO_TIME_SLICE, TX_AUTO_START);
}
