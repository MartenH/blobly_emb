module main

// e2e: build the example, run the binary in a scratch cwd, and drive it through
// the sim's file mirror — button file in, LED file out (docs/io.md sim story).
// Exercised for real: a pressed input reaches the app as a signal (REQ-IO-001),
// the app's output signal reaches the pin (REQ-IO-002), and the output holds its
// configured init from startup, before any press (REQ-IO-009).
// @verifies REQ-IO-001 REQ-IO-002 REQ-IO-009 REQ-IO-012 REQ-IO-013

import os
import time

fn test_button_drives_led() {
	dir := os.real_path(os.dir(@FILE))
	build := os.execute('make -C ${dir}')
	assert build.exit_code == 0, build.output

	// run in a scratch cwd so io/ never lands in the example dir
	work := os.join_path(os.temp_dir(), 'io_gpio_e2e_${os.getpid()}')
	os.rmdir_all(work) or {}
	os.mkdir_all(work)!
	mut p := os.new_process(os.join_path(dir, 'bin', 'app'))
	p.set_work_folder(work)
	p.run()
	defer {
		p.signal_kill()
		p.wait()
		os.rmdir_all(work) or {}
	}

	// startup: the output file exists at its configured init (0) — established
	// by io.init() before any app code ran, and no press has happened yet
	time.sleep(200 * time.millisecond)
	led := os.join_path(work, 'io', 'LedGreen')
	assert os.exists(led), 'io/LedGreen missing after startup'
	assert (os.read_file(led) or { '' }).trim_space() == '0'

	// press the button via the ioset protocol (write-then-rename, atomic)
	tmp := os.join_path(work, 'io', '.UserButton.tmp')
	os.write_file(tmp, '1\n')!
	os.rename(tmp, os.join_path(work, 'io', 'UserButton'))!

	// input -> signal -> FB -> signal -> output, within the io/app cadences
	mut lit := false
	for _ in 0 .. 200 {
		if (os.read_file(led) or { '' }).trim_space() == '1' {
			lit = true
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert lit, 'LedGreen never followed the pressed UserButton'
}
