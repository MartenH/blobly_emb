/* sysnode's screen ([display], boards/h735dk/display.h): the gateway's own status, read from state
 * the node already keeps — nothing here is a signal (that is the next step: signals reach the
 * display through IOC channels of their own). Two tabs: Overview (uptime, CPU, the display's own
 * cost) and Buses (compute and edge CAN, Ethernet and DoIP).
 *
 * Every read is of a single-writer word or a read-only register: the core's load (display.c's
 * idle thread), the FB overrun count (comm_glue.c's load cells), the link and DoIP flags the net threads write, and the FDCANs' PSR/ECR — whose
 * read-to-clear fields (LEC, CEL) the CAN driver does not use; it reads PSR.BO alone.
 */
#include <stm32h735xx.h>
#include "tx_api.h"
#include "board.h"
#include "display.h"
#include "touch.h"
#include "lvgl.h"

unsigned load_sum_overruns(void);
unsigned long blob_net_addr(void);
extern volatile unsigned long net_link_up;
int doip_net_ready(void);
int doip_stream_open(void);

typedef struct {
	lv_obj_t *state, *counters;
} can_row_t;

static lv_obj_t *g_uptime, *g_cpu_bar, *g_cpu_lbl, *g_disp_lbl;
static can_row_t g_can[2];
static lv_obj_t *g_link, *g_doip;
static uint32_t g_last_s = 0xFFFFFFFFu, g_last_cpu = 0xFFFFFFFFu, g_last_disp = 0xFFFFFFFFu;
static uint32_t g_last_can[2] = { 0xFFFFFFFFu, 0xFFFFFFFFu }, g_last_net = 0xFFFFFFFFu;

/* light theme, dark text: the panel's contrast and viewing angle favour it over a dark one */
#define COL_BG    0xe9edf2
#define COL_CARD  0xffffff
#define COL_TEXT  0x111418
#define COL_MUTED 0x4a5363
#define COL_TRACK 0xd3d9e2
#define COL_BLUE  0x1559c7
#define COL_GREEN 0x0b7a3e
#define COL_AMBER 0xa85d00
#define COL_RED   0xc01818

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

static lv_obj_t *page(lv_obj_t *tab) {
	lv_obj_set_flex_flow(tab, LV_FLEX_FLOW_COLUMN);
	lv_obj_set_style_pad_all(tab, 8, 0);
	lv_obj_set_style_pad_row(tab, 8, 0);
	return tab;
}

void ui_create(void) {
	lv_display_t *disp = lv_display_get_default();
	lv_display_set_theme(disp, lv_theme_default_init(disp, lv_color_hex(COL_BLUE), lv_color_hex(COL_GREEN), false,
	                                                 &lv_font_montserrat_14));
	lv_obj_t *scr = lv_screen_active();
	lv_obj_set_style_bg_color(scr, lv_color_hex(COL_BG), 0);
	lv_obj_set_style_text_color(scr, lv_color_hex(COL_TEXT), 0);

	lv_obj_t *tv = lv_tabview_create(scr);
	lv_tabview_set_tab_bar_size(tv, 36);
	lv_obj_set_style_bg_color(tv, lv_color_hex(COL_BG), 0);
	lv_obj_t *ov = page(lv_tabview_add_tab(tv, "Overview"));
	lv_obj_t *bus = page(lv_tabview_add_tab(tv, "Buses"));

	lv_obj_t *c = card(ov, "sysnode  |  Central Gateway");
	g_uptime = value(c);
	c = card(ov, "CPU (every thread and interrupt, last second)");
	g_cpu_lbl = value(c);
	g_cpu_bar = lv_bar_create(c);
	lv_obj_set_size(g_cpu_bar, LV_PCT(100), 6);
	lv_bar_set_range(g_cpu_bar, 0, 1000);
	lv_obj_set_style_bg_color(g_cpu_bar, lv_color_hex(COL_TRACK), LV_PART_MAIN);
	lv_obj_set_style_bg_color(g_cpu_bar, lv_color_hex(COL_BLUE), LV_PART_INDICATOR);
	c = card(ov, "Display thread");
	g_disp_lbl = value(c);

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
	uint32_t disp = display_load_pm | (display_fps << 16);
	if (disp != g_last_disp) {
		g_last_disp = disp;
		const char *chip = display_touch_chip == TOUCH_GT911 ? "GT911" : display_touch_chip == TOUCH_FT5336 ? "FT5336" : "none";
		lv_label_set_text_fmt(g_disp_lbl, "%u.%u%% CPU, %u fps   touch %s", (unsigned)(display_load_pm / 10u),
		                      (unsigned)(display_load_pm % 10u), (unsigned)display_fps, chip);
	}
	can_update(0, FDCAN1);
	can_update(1, FDCAN2);
	uint32_t net = (uint32_t)net_link_up | ((uint32_t)doip_net_ready() << 1) | ((uint32_t)doip_stream_open() << 2);
	if (net != g_last_net) {
		g_last_net = net;
		unsigned long ip = blob_net_addr();
		lv_label_set_text_fmt(g_link, "link %s   %u.%u.%u.%u", net_link_up ? "up" : "down", (unsigned)(ip >> 24),
		                      (unsigned)(ip >> 16 & 0xFFu), (unsigned)(ip >> 8 & 0xFFu), (unsigned)(ip & 0xFFu));
		lv_label_set_text_fmt(g_doip, "DoIP %s   tester %s", doip_net_ready() ? "listening" : "down",
		                      doip_stream_open() ? "connected" : "none");
	}
}
