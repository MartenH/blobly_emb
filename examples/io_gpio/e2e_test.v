module main

// e2e: build the example, run the binary in a scratch cwd, and drive it through
// the sim's file mirror — button file in, LED file out (docs/io.md sim story).
// Exercised for real: a pressed input reaches the app as a signal (REQ-IO-001),
// the app's output signal reaches the pin (REQ-IO-002), and the output holds its
// configured init (1 — deliberately distinct from the app's unpressed command 0)
// from startup, BEFORE the first app command (REQ-IO-009). The startup-fault leg
// is observed too: io/UserButton is absent at boot, so the counted fault must
// surface on stderr.
// @verifies REQ-IO-001 REQ-IO-002 REQ-IO-009 REQ-IO-012 REQ-IO-013

import os
import time

fn test_button_drives_led() {
	dir := os.real_path(os.dir(@FILE))
	// V=@VEXE: the nested make must use the V running THIS test, not rely on PATH
	build := os.execute('make -C ${dir} V=${os.quoted_path(@VEXE)}')
	assert build.exit_code == 0, build.output

	// run in a scratch cwd so io/ never lands in the example dir
	work := os.join_path(os.temp_dir(), 'io_gpio_e2e_${os.getpid()}')
	os.rmdir_all(work) or {}
	os.mkdir_all(work)!
	mut p := os.new_process(os.join_path(dir, 'bin', 'app'))
	p.set_work_folder(work)
	p.set_redirect_stdio() // capture stderr: the startup-fault diagnostic leg
	p.run()
	defer {
		p.signal_kill()
		p.wait()
		os.rmdir_all(work) or {}
	}

	// startup: run() prints the fault line AFTER io init + boot publish and
	// BEFORE spawning any thread — a deterministic barrier. At that instant
	// LedGreen must already hold the driver-established init (1); no thread
	// has run yet, so a loaded host cannot race the app's first command past
	// this assert.
	led := os.join_path(work, 'io', 'LedGreen')
	mut barrier := ''
	for _ in 0 .. 5000 {
		barrier = p.stderr_read()
		if barrier.contains('startup fault') {
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert barrier.contains('startup fault'), 'no pre-spawn stderr barrier observed'
	first := (os.read_file(led) or { '' }).trim_space()
	assert first == '1', 'at the pre-spawn barrier LedGreen was "${first}" — init (1) not established'

	// then the app's first command lands: 0, button unpressed. With no
	// io/UserButton file the checked reads publish NOTHING, so this 0 is the
	// FB running on its port default (false), never a fabricated sample.
	mut cleared := false
	for _ in 0 .. 500 {
		if (os.read_file(led) or { '' }).trim_space() == '0' {
			cleared = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert cleared, 'LedGreen never left init for the unpressed app command'
	// the fault-leg proof: the input file still must not exist here — nothing
	// seeded it, so the 0 above cannot have come from a published sample
	assert !os.exists(os.join_path(work, 'io', 'UserButton')), 'io/UserButton exists before the test wrote it — an input was seeded'
	// ...and the fault must be OBSERVED, not just counted: io/UserButton was
	// absent at boot, so run() must have reported it on stderr (REQ-IO-009)
	// (the stderr barrier above already proved the observable fault report)

	// press the button via the ioset protocol (write-then-rename, atomic)
	tmp := os.join_path(work, 'io', '.UserButton.tmp')
	os.write_file(tmp, '1\n')!
	os.rename(tmp, os.join_path(work, 'io', 'UserButton'))!

	// input -> signal -> FB -> signal -> output, within the io/app cadences
	// bound = a handful of 10 ms cadences (input publish + handler + output
	// apply), NOT seconds — a 1 Hz regression must fail REQ-IO-012/013
	mut lit := false
	for _ in 0 .. 100 {
		if (os.read_file(led) or { '' }).trim_space() == '1' {
			lit = true
			break
		}
		time.sleep(1 * time.millisecond)
	}
	assert lit, 'LedGreen did not follow UserButton within ~10 io/app cadences'
}
