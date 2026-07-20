# system_io — build + flash the two-node button->lamp system generated from one
# system.toml. `make` generates both node ecu.tomls (the dissolution) and builds
# each to a flashable binary; flash each board by its ST-LINK serial.
#
#   make                                  # gen-system + build both nodes
#   make flash-h755 H755_SERIAL=<serial>  # flash the NUCLEO-H755ZI-Q (button)
#   make flash-h735 H735_SERIAL=<serial>  # flash the STM32H735G-DK  (lamp)
# Wire both boards on one CAN bus; press B1 on the H755 -> the H735 LED follows.

all: h755 h735

gen:
	$(MAKE) -C ../.. gen-system SYSTEM=examples/system_io/system.toml

h755: gen
	$(MAKE) -C nodes/h755 all

h735: gen
	$(MAKE) -C nodes/h735 all

flash-h755: h755
	$(MAKE) -C nodes/h755 flash SERIAL=$(H755_SERIAL)

flash-h735: h735
	$(MAKE) -C nodes/h735 flash SERIAL=$(H735_SERIAL)

clean:
	-$(MAKE) -C nodes/h755 clean
	-$(MAKE) -C nodes/h735 clean

.PHONY: all gen h755 h735 flash-h755 flash-h735 clean
