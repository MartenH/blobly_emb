module io

// Host-backend (file mirror) driver tests: init seeding, write/read
// round-trip, last-good on garbage, temp-rename hygiene. Each test runs in
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

fn test_init_creates_files_with_init_values() {
	dir := setup('init')
	assert cfg(0, 'LedGreen', 'PB0', true, 1)
	assert cfg(1, 'UserButton', 'PC13', false, 0)
	assert init()
	assert os.read_file('io/LedGreen')!.trim_space() == '1'
	assert os.read_file('io/UserButton')!.trim_space() == '0'
	teardown(dir)
}

fn test_write_read_round_trip() {
	dir := setup('rt')
	assert cfg(0, 'LedGreen', 'PB0', true, 0)
	assert init()
	gpio_write(0, true)
	assert gpio_read(0) == true
	gpio_write(0, false)
	assert gpio_read(0) == false
	teardown(dir)
}

fn test_garbage_file_returns_last_good() {
	dir := setup('lastgood')
	assert cfg(0, 'UserButton', 'PC13', false, 0)
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
	teardown(dir)
}

fn test_temp_rename_leaves_no_tmp() {
	dir := setup('tmp')
	assert cfg(0, 'LedGreen', 'PB0', true, 0)
	assert init()
	gpio_write(0, true)
	assert !os.exists('io/.LedGreen.drv.tmp')
	files := os.ls('io')!
	assert files == ['LedGreen']
	teardown(dir)
}
