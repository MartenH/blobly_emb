module main

// @verifies REQ-IO-018 REQ-IO-019
// The ADC path end to end on the file mirror: poking the analog input (a full
// u16 count) drives the Meter FB across mid-scale, flipping LedHi. Proves
// config -> codegen -> io.adc_read -> FB -> io.gpio_write in the generated stack.

import os
import time

fn test_analog_input_drives_threshold_led() {
	dir := os.real_path(os.dir(@FILE))
	build := os.execute('make -C ${dir} V=${os.quoted_path(@VEXE)}')
	assert build.exit_code == 0, build.output

	work := os.join_path(os.temp_dir(), 'io_adc_e2e_${os.getpid()}')
	os.rmdir_all(work) or {}
	os.mkdir_all(work)!
	os.mkdir_all(os.join_path(work, 'io'))!
	pot := os.join_path(work, 'io', 'PotVolt')
	led := os.join_path(work, 'io', 'LedHi')
	// seed a real analog sample BEFORE launch so the boot publish reads it
	os.write_file(pot, '1000\n')!

	mut p := os.new_process(os.join_path(dir, 'bin', 'app'))
	p.set_work_folder(work)
	p.run()
	defer {
		p.signal_kill()
		p.wait()
		os.rmdir_all(work) or {}
	}

	// low pot (1000 < 2048) -> LedHi 0
	mut ok := false
	for _ in 0 .. 500 {
		if (os.read_file(led) or { '' }).trim_space() == '0' {
			ok = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert ok, 'LedHi never settled to 0 for a low analog input'

	// raise the pot above mid-scale -> LedHi 1
	os.write_file(pot, '3500\n')!
	ok = false
	for _ in 0 .. 500 {
		if (os.read_file(led) or { '' }).trim_space() == '1' {
			ok = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert ok, 'LedHi never lit when the analog input crossed mid-scale'

	// drop it back -> LedHi 0 (full-range u16 value, not a 0/1 gpio coercion)
	os.write_file(pot, '200\n')!
	ok = false
	for _ in 0 .. 500 {
		if (os.read_file(led) or { '' }).trim_space() == '0' {
			ok = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert ok, 'LedHi never cleared when the analog input dropped'
}
