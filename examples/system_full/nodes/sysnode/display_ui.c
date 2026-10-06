/* sysnode's screen ([display], boards/h735dk/display.h): the gateway's own status, read from state
 * the node already keeps — nothing here is a signal (that is the next step: signals reach the
 * display through IOC channels of their own). Three tabs:
 *   Overview  uptime, the whole core's CPU, the display's frame rate and touch controller
 *   Threads   every ThreadX thread and the interrupts, with the last second's CPU of each
 *   Buses     compute and edge CAN, Ethernet and DoIP
 * Under every tab, an LED chaser strip: two rows of dots, a comet hopping one dot per tick at 10 Hz —
 * compute -> edge on top, edge -> compute below, like frames routed both ways. Motion meant to be
 * discrete reads well at 10 Hz where a gliding one would stutter, and each tick recolours only a
 * dozen 6-pixel dots (drifting blobs measured 51% of the core; the strip costs a few percent).
 *
 * Every read is of a single-writer word or a read-only register: the CPU figures (display.c, from
 * cpuprof.c's samples), the FB overrun count (comm_glue.c's load cells), the link and DoIP flags the
 * net threads write, and the FDCANs' PSR/ECR — whose read-to-clear fields (LEC, CEL) the CAN driver
 * does not use; it reads PSR.BO alone.
 */
#include <stm32h735xx.h>
#include "tx_api.h"
#include "board.h"
#include "display.h"
#include "touch.h"
#include "netx_up.h"
#include "lvgl.h"

/* no header declares these (comm_glue.c, driver/eth/doip_netx.c) */
unsigned load_sum_overruns(void);
int doip_net_ready(void);
int doip_stream_open(void);

/* light theme, dark text: the panel's contrast and viewing angle favour it over a dark one */
#define COL_BG    0xe9edf2
#define COL_CARD  0xffffff
#define COL_TEXT  0x111418
#define COL_MUTED 0x4a5363
#define COL_TRACK 0xd3d9e2
#define COL_TAB   0xc5ccd6
#define COL_BLUE  0x1559c7
#define COL_GREEN 0x0b7a3e
#define COL_AMBER 0xa85d00
#define COL_RED   0xc01818

typedef struct {
	lv_obj_t *state, *counters;
} can_row_t;

static lv_obj_t *g_uptime, *g_cpu_bar, *g_cpu_lbl, *g_disp_lbl, *g_threads;
static can_row_t g_can[2];
static lv_obj_t *g_link, *g_doip;
static uint32_t g_last_s = 0xFFFFFFFFu, g_last_cpu = 0xFFFFFFFFu, g_last_disp = 0xFFFFFFFFu;
static uint32_t g_last_can[2] = { 0xFFFFFFFFu, 0xFFFFFFFFu }, g_last_net = 0xFFFFFFFFu;
static uint32_t g_shown_gen; /* the table is rebuilt when display.c refreshes the loads */

static lv_obj_t *card(lv_obj_t *parent, const char *title) {
	lv_obj_t *c = lv_obj_create(parent);
	lv_obj_set_size(c, LV_PCT(100), LV_SIZE_CONTENT);
	lv_obj_set_flex_flow(c, LV_FLEX_FLOW_COLUMN);
	lv_obj_set_style_pad_all(c, 8, 0);
	lv_obj_set_style_pad_row(c, 4, 0);
	lv_obj_set_style_bg_color(c, lv_color_hex(COL_CARD), 0);
	lv_obj_set_style_text_color(c, lv_color_hex(COL_TEXT), 0);
	lv_obj_set_style_border_width(c, 0, 0);
	lv_obj_set_scrollable(c, false);
	lv_obj_t *t = lv_label_create(c);
	lv_label_set_text(t, title);
	lv_obj_set_style_text_color(t, lv_color_hex(COL_MUTED), 0);
	return c;
}

/* a value line: the larger font, so the numbers read at a glance */
static lv_obj_t *value(lv_obj_t *card) {
	lv_obj_t *l = lv_label_create(card);
	lv_label_set_text(l, "");
	lv_obj_set_style_text_font(l, &lv_font_montserrat_20, 0);
	return l;
}

#define STRIP_H    22
#define STRIP_DOTS 46
#define DOT        6
#define COMET      6 /* the comet's length in dots, brightest first */

static lv_obj_t *g_strip;
static uint32_t g_step;

/* comet colour at `age` dots behind the head: the hue faded toward the strip's background */
static lv_color_t comet(uint32_t hue, int age) {
	static const uint8_t mix[COMET] = { 255, 200, 150, 105, 65, 35 };
	return lv_color_mix(lv_color_hex(hue), lv_color_hex(COL_TRACK), mix[age]);
}

/* the strip draws its own dots: ONE object, so a tick is one dirty area. As 92 dot objects it
 * was 92 — past LVGL's 32 (LV_INV_BUF_SIZE), where it gives up and redraws the whole screen. */
static void strip_draw(lv_event_t *e) {
	static const uint32_t hue[2] = { COL_BLUE, COL_GREEN };
	lv_layer_t *layer = lv_event_get_layer(e);
	lv_area_t c;
	lv_obj_get_coords(g_strip, &c);
	const int32_t pitch = 480 / STRIP_DOTS, x0 = c.x1 + (480 - pitch * (STRIP_DOTS - 1) - DOT) / 2;
	lv_draw_rect_dsc_t d;
	lv_draw_rect_dsc_init(&d);
	d.radius = LV_RADIUS_CIRCLE;
	d.bg_opa = LV_OPA_COVER;
	for (int r = 0; r < 2; r++) {
		/* row 0 runs left to right, row 1 right to left; each has two comets half a strip apart */
		for (int i = 0; i < STRIP_DOTS; i++) {
			int pos = r == 0 ? i : STRIP_DOTS - 1 - i;
			int age = ((int)g_step - pos) % (STRIP_DOTS / 2);
			if (age < 0) age += STRIP_DOTS / 2;
			d.bg_color = age < COMET ? comet(hue[r], age) : lv_color_hex(COL_TRACK);
			lv_area_t dot = { x0 + i * pitch, c.y1 + 3 + r * (DOT + 4), 0, 0 };
			dot.x2 = dot.x1 + DOT - 1;
			dot.y2 = dot.y1 + DOT - 1;
			lv_draw_rect(layer, &d, &dot);
		}
	}
}

static void strip_tick(lv_timer_t *t) {
	(void)t;
	g_step++;
	lv_obj_invalidate(g_strip);
}

/* the chaser strip along the bottom of the screen, under every tab */
static void strip(lv_obj_t *scr) {
	g_strip = lv_obj_create(scr);
	lv_obj_remove_style_all(g_strip);
	lv_obj_set_size(g_strip, LV_PCT(100), STRIP_H);
	lv_obj_align(g_strip, LV_ALIGN_BOTTOM_MID, 0, 0);
	lv_obj_set_style_bg_color(g_strip, lv_color_hex(COL_CARD), 0);
	lv_obj_set_style_bg_opa(g_strip, LV_OPA_COVER, 0);
	lv_obj_add_event_cb(g_strip, strip_draw, LV_EVENT_DRAW_MAIN, 0);
	lv_timer_create(strip_tick, 100, 0); /* 10 Hz */
}

static lv_obj_t *page(lv_obj_t *tab) {
	lv_obj_set_style_bg_opa(tab, LV_OPA_TRANSP, 0);
	lv_obj_set_flex_flow(tab, LV_FLEX_FLOW_COLUMN);
	lv_obj_set_style_pad_all(tab, 6, 0);
	lv_obj_set_style_pad_row(tab, 6, 0);
	return tab;
}

/* the selected tab is the bright one: white with blue text over a darker bar */
static void style_tabs(lv_obj_t *tv) {
	lv_obj_t *bar = lv_tabview_get_tab_bar(tv);
	lv_obj_set_style_bg_color(bar, lv_color_hex(COL_TAB), 0);
	lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
	for (uint32_t i = 0; i < lv_obj_get_child_count(bar); i++) {
		lv_obj_t *b = lv_obj_get_child(bar, (int32_t)i);
		lv_obj_set_style_bg_opa(b, LV_OPA_TRANSP, 0);
		lv_obj_set_style_text_color(b, lv_color_hex(COL_MUTED), 0);
		lv_obj_set_style_bg_opa(b, LV_OPA_COVER, LV_STATE_CHECKED);
		lv_obj_set_style_bg_color(b, lv_color_hex(COL_CARD), LV_STATE_CHECKED);
		lv_obj_set_style_text_color(b, lv_color_hex(COL_BLUE), LV_STATE_CHECKED);
		lv_obj_set_style_border_color(b, lv_color_hex(COL_BLUE), LV_STATE_CHECKED);
	}
}

void ui_create(void) {
	lv_display_t *disp = lv_display_get_default();
	lv_display_set_theme(disp, lv_theme_default_init(disp, lv_color_hex(COL_BLUE), lv_color_hex(COL_GREEN), false,
	                                                 &lv_font_montserrat_14));
	lv_obj_t *scr = lv_screen_active();
	lv_obj_set_style_bg_color(scr, lv_color_hex(COL_BG), 0);
	lv_obj_set_style_text_color(scr, lv_color_hex(COL_TEXT), 0);
	lv_obj_set_scrollable(scr, false);

	lv_obj_t *tv = lv_tabview_create(scr);
	lv_obj_set_size(tv, LV_PCT(100), 272 - STRIP_H);
	lv_obj_align(tv, LV_ALIGN_TOP_MID, 0, 0);
	lv_tabview_set_tab_bar_size(tv, 36);
	lv_obj_set_style_bg_color(tv, lv_color_hex(COL_BG), 0);
	lv_obj_t *ov = page(lv_tabview_add_tab(tv, "Overview"));
	lv_obj_t *thr = page(lv_tabview_add_tab(tv, "Threads"));
	lv_obj_t *bus = page(lv_tabview_add_tab(tv, "Buses"));
	style_tabs(tv);

	lv_obj_t *c = card(ov, "sysnode  |  Central Gateway");
	g_uptime = value(c);
	c = card(ov, "CPU (every thread and interrupt, last second)");
	g_cpu_lbl = value(c);
	g_cpu_bar = lv_bar_create(c);
	lv_obj_set_size(g_cpu_bar, LV_PCT(100), 6);
	lv_bar_set_range(g_cpu_bar, 0, 1000);
	lv_obj_set_style_bg_color(g_cpu_bar, lv_color_hex(COL_TRACK), LV_PART_MAIN);
	lv_obj_set_style_bg_color(g_cpu_bar, lv_color_hex(COL_BLUE), LV_PART_INDICATOR);
	c = card(ov, "Display");
	g_disp_lbl = value(c);

	g_threads = lv_table_create(thr);
	lv_obj_set_width(g_threads, LV_PCT(100));
	lv_table_set_column_count(g_threads, 3);
	lv_table_set_column_width(g_threads, 0, 250);
	lv_table_set_column_width(g_threads, 1, 70);
	lv_table_set_column_width(g_threads, 2, 120);
	lv_obj_set_style_pad_ver(g_threads, 4, LV_PART_ITEMS);
	lv_table_set_cell_value(g_threads, 0, 0, "thread");
	lv_table_set_cell_value(g_threads, 0, 1, "prio");
	lv_table_set_cell_value(g_threads, 0, 2, "CPU");

	static const char *const names[2] = { "CAN compute (FDCAN1)", "CAN edge (FDCAN2)" };
	for (int i = 0; i < 2; i++) {
		c = card(bus, names[i]);
		g_can[i].state = value(c);
		g_can[i].counters = lv_label_create(c);
		lv_label_set_text(g_can[i].counters, "");
	}
	c = card(bus, "Ethernet / DoIP");
	g_link = lv_label_create(c);
	g_doip = lv_label_create(c);

	strip(scr);
}

static void can_update(int i, FDCAN_GlobalTypeDef *f) {
	uint32_t psr = f->PSR, ecr = f->ECR;
	uint32_t tec = ecr & FDCAN_ECR_TEC_Msk, rec = (ecr & FDCAN_ECR_REC_Msk) >> FDCAN_ECR_REC_Pos;
	uint32_t init = f->CCCR & FDCAN_CCCR_INIT;
	uint32_t key = (psr & (FDCAN_PSR_BO | FDCAN_PSR_EP | FDCAN_PSR_EW)) | (tec << 8) | (rec << 16) | (init << 31);
	if (key == g_last_can[i]) return;
	g_last_can[i] = key;
	const char *st = (psr & FDCAN_PSR_BO) ? "BUS-OFF" : (psr & FDCAN_PSR_EP) ? "error passive"
	               : (psr & FDCAN_PSR_EW) ? "warning" : init ? "stopped" : "active";
	lv_color_t col = (psr & FDCAN_PSR_BO) ? lv_color_hex(COL_RED) : (psr & (FDCAN_PSR_EP | FDCAN_PSR_EW))
	               ? lv_color_hex(COL_AMBER) : lv_color_hex(COL_GREEN);
	lv_label_set_text(g_can[i].state, st);
	lv_obj_set_style_text_color(g_can[i].state, col, 0);
	lv_label_set_text_fmt(g_can[i].counters, "TX errors %u   RX errors %u", (unsigned)tec, (unsigned)rec);
}

/* the Threads table, rebuilt once a second (when display.c refreshes the loads), busiest first */
static void threads_update(void) {
	const display_load_t *l;
	uint32_t gen;
	int n = display_loads(&l, &gen);
	if (n == 0 || gen == g_shown_gen) return;
	g_shown_gen = gen;
	int order[24];
	int k = n < 24 ? n : 24;
	for (int i = 0; i < k; i++) order[i] = i;
	for (int i = 1; i < k; i++) { /* insertion sort by CPU, descending */
		int v = order[i], j = i - 1;
		while (j >= 0 && l[order[j]].pm < l[v].pm) {
			order[j + 1] = order[j];
			j--;
		}
		order[j + 1] = v;
	}
	lv_table_set_row_count(g_threads, (uint32_t)k + 1u);
	for (int r = 0; r < k; r++) {
		const display_load_t *e = &l[order[r]];
		lv_table_set_cell_value(g_threads, (uint32_t)r + 1u, 0, e->name);
		if (e->prio == DISPLAY_NO_PRIO) lv_table_set_cell_value(g_threads, (uint32_t)r + 1u, 1, "-");
		else lv_table_set_cell_value_fmt(g_threads, (uint32_t)r + 1u, 1, "%u", e->prio);
		lv_table_set_cell_value_fmt(g_threads, (uint32_t)r + 1u, 2, "%u.%u%%", (unsigned)(e->pm / 10u),
		                            (unsigned)(e->pm % 10u));
	}
}

void ui_update(void) {
	uint32_t s = (uint32_t)(board_now_us() / 1000000u);
	if (s != g_last_s) {
		g_last_s = s;
		lv_label_set_text_fmt(g_uptime, "up %u d %02u:%02u:%02u", (unsigned)(s / 86400u), (unsigned)(s / 3600u % 24u),
		                      (unsigned)(s / 60u % 60u), (unsigned)(s % 60u));
	}
	uint32_t cpu = display_cpu_pm, ovr = load_sum_overruns();
	if ((cpu | (ovr << 16)) != g_last_cpu) {
		g_last_cpu = cpu | (ovr << 16);
		lv_bar_set_value(g_cpu_bar, (int32_t)cpu, LV_ANIM_OFF);
		lv_label_set_text_fmt(g_cpu_lbl, "%u.%u%%   FB overruns %u", (unsigned)(cpu / 10u), (unsigned)(cpu % 10u),
		                      (unsigned)ovr);
	}
	uint32_t disp = display_fps | ((uint32_t)display_touch_chip << 16);
	if (disp != g_last_disp) {
		g_last_disp = disp;
		const char *chip = display_touch_chip == TOUCH_GT911 ? "GT911" : display_touch_chip == TOUCH_FT5336 ? "FT5336" : "none";
		lv_label_set_text_fmt(g_disp_lbl, "%u fps   touch %s", (unsigned)display_fps, chip);
	}
	threads_update();
	can_update(0, FDCAN1);
	can_update(1, FDCAN2);
	uint32_t net = (uint32_t)net_link_up | ((uint32_t)doip_net_ready() << 1) | ((uint32_t)doip_stream_open() << 2);
	if (net != g_last_net) {
		g_last_net = net;
		ULONG ip = blob_net_addr();
		lv_label_set_text_fmt(g_link, "link %s   %u.%u.%u.%u", net_link_up ? "up" : "down", (unsigned)(ip >> 24),
		                      (unsigned)(ip >> 16 & 0xFFu), (unsigned)(ip >> 8 & 0xFFu), (unsigned)(ip & 0xFFu));
		lv_label_set_text_fmt(g_doip, "DoIP %s   tester %s", doip_net_ready() ? "listening" : "down",
		                      doip_stream_open() ? "connected" : "none");
	}
}
