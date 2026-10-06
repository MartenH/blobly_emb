# boards/h735dk/display.mk — the H735-DK display ([display] in ecu.toml): LVGL as a pinned archive,
# and the board's display sources (display.c's thread, the LCD, touch and HyperRAM drivers).
# Included by gen/loom_build.mk when the node declares [display], after board.mk; the including
# Makefile adds $(DISPLAY_SRCS) and $(LVGL_A) to its link and $(DISPLAY_CFLAGS) to its CFLAGS, and
# provides the screen (ui_create / ui_update, boards/h735dk/display.h) in its own C.
#
# LVGL is OPTIONAL in `make deps`: fetch it with `make -C $(REPO) deps-lvgl`.
LVGL           = $(REPO)/third_party/lvgl
DISPLAY_CFLAGS = -DLV_CONF_INCLUDE_SIMPLE -I$(LVGL)
DISPLAY_SRCS   = $(BOARD_DIR)/display.c $(BOARD_DIR)/lcd.c $(BOARD_DIR)/touch.c $(BOARD_DIR)/hyperram.c
LVGL_A         = $(BUILD)/lvgl.a
LVGL_C         = $(shell find $(LVGL)/src -name '*.c' 2>/dev/null)
LVGL_OBJ       = $(patsubst $(LVGL)/src/%.c,$(BUILD)/lvgl/%.o,$(LVGL_C))

# LVGL at -O2: its software renderer is the display thread's whole cost; -O2 took the demonstrator
# from ~21.5% to ~18.5% of the CPU for ~85 KB of flash. A pinned third-party archive, rebuilt when
# its configuration changes, like the ThreadX objects (scripts/app_deps_check.sh exempts both).
$(BUILD)/lvgl/%.o: $(LVGL)/src/%.c $(BOARD_DIR)/lv_conf.h $(BOARD_DIR)/lv_attr.h $(BOARD_DIR)/display.mk
	@mkdir -p $(dir $@)
	@$(CC) $(CFLAGS) $(DISPLAY_CFLAGS) -O2 -c $< -o $@
$(LVGL_A): $(LVGL_OBJ)
	@[ -n "$(LVGL_C)" ] || { echo "LVGL missing: run make -C $(REPO) deps-lvgl"; exit 1; }
	@$(AR) -rc $@ $^
