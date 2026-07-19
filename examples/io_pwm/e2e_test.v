module main

// @verifies REQ-IO-021
// The PWM path end to end on the file mirror: the analog input ramps the FanDuty
// output through the Dimmer FB; the mirror holds the duty permille (not a 0/1
// gpio value). Proves config -> codegen -> io.pwm_write in the generated stack.

import os
import time

fn read_duty(path string) int {
	return (os.read_file(path) or { '' }).trim_space().int()
}

fn test_pot_ramps_pwm_duty() {
	dir := os.real_path(os.dir(@FILE))
	build := os.execute('make -C ${dir} V=${os.quoted_path(@VEXE)}')
	assert build.exit_code == 0, build.output

	work := os.join_path(os.temp_dir(), 'io_pwm_e2e_${os.getpid()}')
	os.rmdir_all(work) or {}
	os.mkdir_all(os.join_path(work, 'io'))!
	pot := os.join_path(work, 'io', 'Pot')
	duty := os.join_path(work, 'io', 'FanDuty')
	os.write_file(pot, '0\n')!

	mut p := os.new_process(os.join_path(dir, 'bin', 'app'))
	p.set_work_folder(work)
	p.run()
	defer {
		p.signal_kill()
		p.wait()
		os.rmdir_all(work) or {}
	}

	// full-scale pot -> duty near 1000 (a full permille, not a gpio 0/1)
	os.write_file(pot, '4095\n')!
	mut hi := false
	for _ in 0 .. 500 {
		if read_duty(duty) >= 990 {
			hi = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert hi, 'FanDuty never reached full scale for a full-scale pot'

	// mid pot -> ~500 permille (proves it is a proportional duty, not a level)
	os.write_file(pot, '2048\n')!
	mut mid := false
	for _ in 0 .. 500 {
		d := read_duty(duty)
		if d > 450 && d < 550 {
			mid = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert mid, 'FanDuty never tracked mid-scale as a proportional duty'
}
