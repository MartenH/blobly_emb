# boards/h735dk/display.mk — the H735-DK display ([display] in ecu.toml): LVGL as a pinned archive,
# and the board's display sources (display.c's thread, the LCD, touch and HyperRAM drivers).
# Included by gen/loom_build.mk when the node declares [display], after board.mk; the including
# Makefile adds $(DISPLAY_SRCS) and $(LVGL_A) to its link and $(DISPLAY_CFLAGS) to its CFLAGS, and
# provides the screen (ui_create / ui_update, boards/h735dk/display.h) in its own C.
#
# LVGL is OPTIONAL in `make deps`: fetch it with `make -C $(REPO) deps-lvgl`.
LVGL           = $(REPO)/third_party/lvgl
DISPLAY_CFLAGS = -DLV_CONF_INCLUDE_SIMPLE -I$(LVGL)
DISPLAY_SRCS   = $(BOARD_DIR)/display.c $(BOARD_DIR)/lcd.c $(BOARD_DIR)/touch.c $(BOARD_DIR)/hyperram.c \
                 $(BOARD_DIR)/cpuprof.c
LVGL_A         = $(BUILD)/lvgl.a
# LVGL ships code for other platforms and for options this board's lv_conf.h turns off: host and OS
# display drivers, other chips' GPU backends, the image/font decoder libraries, the alternative stdlib
# and debugging tools. Nothing from them reaches the link, so they are left out (265 of LVGL
# v9.6.0's 483 files, 218 compiled). Turning one of those options on in lv_conf.h
# fails the link with its symbol undefined: take its directory off this list.
LVGL_UNUSED    = drivers libs debugging others widgets/property image/svg \
                 draw/vg_lite draw/nanovg draw/nema_gfx draw/nxp draw/renesas draw/sifli draw/eve \
                 draw/espressif draw/dma2d draw/opengles draw/sdl \
                 font/freetype font/tiny_ttf font/imgfont font/font_manager \
                 stdlib/clib stdlib/rtthread stdlib/micropython stdlib/uefi
LVGL_C        := $(filter-out $(foreach d,$(LVGL_UNUSED),$(LVGL)/src/$(d)/%),$(shell find $(LVGL)/src -name '*.c' 2>/dev/null))
LVGL_OBJ       = $(patsubst $(LVGL)/src/%.c,$(BUILD)/lvgl/%.o,$(LVGL_C))

# LVGL at -O2: its software renderer is the display thread's whole cost; -O2 took the demonstrator
# from ~21.5% to ~18.5% of the CPU for ~85 KB of flash. A pinned third-party archive, compiled
# like the ThreadX objects (tools/tools.mk c_object): each object is remade when a header it reads
# changes (lv_conf.h, lv_attr.h, the forced board.h) and all of them when the command does.
LVGL_CMD       = $(CC) $(CFLAGS) $(DISPLAY_CFLAGS) -O2
$(BUILD)/lvgl/%.o: $(LVGL)/src/%.c $$(call c_unrecorded,$$@) $$(call c_sign,$(BUILD)/lvgl,$$(LVGL_CMD))
	@mkdir -p $(dir $@)
	@$(call c_object,$(LVGL_CMD))
$(LVGL_A): $(LVGL_OBJ) $$(call c_sign,$$@,$$(AR_CMD))
	@[ -n "$(LVGL_C)" ] || { echo "LVGL missing: run make -C $(REPO) deps-lvgl"; exit 1; }
	@$(call c_archive,$(AR_CMD))
-include $(call c_records,$(LVGL_OBJ))
