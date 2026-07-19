module io

// Host-backend (file mirror) driver tests: output-only init seeding, write/
// read round-trip, last-good on garbage, temp-rename hygiene. Each test runs in
// its own temp cwd so io/ never lands in the repo. No REQ tags here:
// REQ-IO-003 is a universal claim (method = review), which a finite unit
// test exercises but cannot verify.

import os

fn setup(tag string) string {
	dir := os.join_path(os.temp_dir(), 'io_drv_${tag}_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	os.chdir(dir) or { panic(err) }
	return dir
}

fn teardown(dir string) {
	close()
	os.chdir(os.temp_dir()) or {}
	os.rmdir_all(dir) or {}
}

fn test_init_creates_output_files_only() {
	dir := setup('init')
	assert cfg(0, 'LedGreen', 'PB0', true, 1, 0, kind_gpio, 0)
	assert cfg(1, 'UserButton', 'PC13', false, 0, 0, kind_gpio, 0)
	assert init()
	assert os.read_file('io/LedGreen')!.trim_space() == '1'
	// input: NO driver-created file — a seeded value would be published at
	// boot as a fabricated "real" sample
	assert !os.exists('io/UserButton')
	assert gpio_read_checked(1) == none // absent: checked read reports failure
	assert gpio_read(1) == false // periodic read serves last-good (cfg init)
	teardown(dir)
}

fn test_write_read_round_trip() {
	dir := setup('rt')
	assert cfg(0, 'LedGreen', 'PB0', true, 0, 0, kind_gpio, 0)
	assert init()
	gpio_write(0, true)
	assert gpio_read(0) == true
	gpio_write(0, false)
	assert gpio_read(0) == false
	teardown(dir)
}

fn test_garbage_file_returns_last_good() {
	dir := setup('lastgood')
	assert cfg(0, 'UserButton', 'PC13', false, 0, 0, kind_gpio, 0)
	assert init()
	os.write_file('io/UserButton', '1\n')!
	assert gpio_read(0) == true // real value: last-good is now 1
	os.write_file('io/UserButton', 'garbage')! // non-conforming writer
	assert gpio_read(0) == true // unparsable: serves last-good
	os.write_file('io/UserButton', '')! // truncated mid-write
	assert gpio_read(0) == true // empty: serves last-good
	os.rm('io/UserButton')!
	assert gpio_read(0) == true // gone: serves last-good
	os.write_file('io/UserButton', '0\n')!
	assert gpio_read(0) == false // conforming again: real value resumes
	os.write_file('io/UserButton', '1garbage')! // parses as 1 + trailing junk
	assert gpio_read(0) == false // rejected whole: serves last-good, not the prefix
	os.write_file('io/UserButton', '1\n')!
	assert gpio_read(0) == true // last-good is 1 again (so rejections below can't pass by luck)
	os.write_file('io/UserButton', '2\n')! // out of gpio domain
	assert gpio_read(0) == true // contract violation: serves last-good, no truthy coercion
	os.write_file('io/UserButton', '-1\n')! // out of gpio domain
	assert gpio_read(0) == true // contract violation: serves last-good
	os.write_file('io/UserButton', '0' + ' '.repeat(80) + '\n')! // > read buffer
	assert gpio_read(0) == true // oversized: completeness unprovable, serves last-good
	teardown(dir)
}

fn test_temp_rename_leaves_no_tmp() {
	dir := setup('tmp')
	assert cfg(0, 'LedGreen', 'PB0', true, 0, 0, kind_gpio, 0)
	assert init()
	gpio_write(0, true)
	assert !os.exists('io/.LedGreen.drv.tmp')
	files := os.ls('io')!
	assert files == ['LedGreen']
	teardown(dir)
}

// This does NOT @verifies REQ-IO-017: the file backend discards active_low by
// design (the host mirror is logical), so this proves only the HALF of the
// requirement that says polarity never leaks ABOVE the driver — cfg accepts
// the flag and the caller's read/write semantics are unchanged. The pad-level
// inversion itself (io_stm32.c) is target-only and bench-verified on the
// H735G-DK's active-low lamp (emb#150); traceability records 017 as bench
// evidence, not unit-verified, so a broken inversion cannot pass unseen here.
fn test_active_low_is_logical_above_the_pad() {
	dir := setup('active_low') // own temp dir + teardown, like every file-backend test
	assert cfg(0, 'LampAL', 'PB0', true, 0, 1, kind_gpio, 0) // active-low lamp, logically off
	assert init()
	gpio_write(0, true) // logically ON
	// the host mirror reads back the LOGICAL value: polarity never leaks up
	assert gpio_read(0) == true
	gpio_write(0, false)
	assert gpio_read(0) == false
	teardown(dir)
}

// @verifies REQ-IO-019
// (value shape end to end. The continuous-scan + circular-DMA requirement is
// hardware-only and bench-pending — a host mirror cannot exercise it.)
// ADC reads a full u16/u32 count from the mirror (not the gpio 0/1 contract);
// last-good on a missing/garbage file, never blocks.
fn test_adc_read_u16_and_last_good() {
	dir := setup('adc')
	assert cfg(0, 'PotVolt', 'PA3', false, 0, 0, kind_adc, 0) // analog input
	assert init()
	os.write_file('io/PotVolt', '3000\n') or { assert false }
	assert adc_read(0) == 3000
	os.write_file('io/PotVolt', '65000\n') or { assert false } // full u16 range
	assert adc_read(0) == 65000
	// garbage -> last-good (3000..65000 was 65000)
	os.write_file('io/PotVolt', 'xyz\n') or { assert false }
	assert adc_read(0) == 65000
	teardown(dir)
}

// @verifies REQ-IO-023
// (duty value semantics — permille + clamp; the timer application itself is
// hardware, bench-pending, not asserted here.)
// PWM writes a duty permille, clamped above 1000; the mirror is logical.
fn test_pwm_write_clamps_permille() {
	dir := setup('pwm')
	assert cfg(0, 'FanDuty', 'PE9', true, 250, 0, kind_pwm, 20000) // init 250‰
	assert init()
	assert os.read_file('io/FanDuty')!.trim_space() == '250' // init duty applied
	pwm_write(0, 750)
	assert os.read_file('io/FanDuty')!.trim_space() == '750'
	pwm_write(0, 5000) // above range -> clamp to 1000
	assert os.read_file('io/FanDuty')!.trim_space() == '1000'
	teardown(dir)
}
