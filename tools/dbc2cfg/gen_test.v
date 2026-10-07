module main

import os
import tools.candb

// A DBC may spell its names however its owner likes; what dbc2cfg refuses is two of them emitting
// one generated identifier.
fn test_name_errors_refuse_a_generated_identifier_twice() {
	db := candb.parse_dbc('VERSION ""
BO_ 256 ABSStatus: 8 ECU
 SG_ Active : 0|1@1+ (1,0) [0|1] "" ECU
BO_ 257 AbsStatus: 8 ECU
 SG_ On : 0|1@1+ (1,0) [0|1] "" ECU
BO_ 258 A_B: 8 ECU
 SG_ C : 0|1@1+ (1,0) [0|1] "" ECU
BO_ 259 A: 8 ECU
 SG_ B_C : 0|1@1+ (1,0) [0|1] "" ECU
 SG_ Speed_Kph : 8|8@1+ (1,0) [0|255] "" ECU
') or {
		panic(err)
	}
	errs := name_errors(db)
	assert errs.any(it == 'frame "AbsStatus" collides with "ABSStatus": both generate `abs_status`'), errs.str()
	assert errs.any(it == 'frame signal "A.B_C" collides with "A_B.C": both generate `a_b_c`'), errs.str()
	assert errs.len == 2, errs.str()
}

// @verifies REQ-COM-010
// The generated code itself: dbc2cfg's output for one DBC, compiled with a test beside it that sets
// values in and beyond each signal's range and reads the raw bits back — the bits on the wire.
fn test_generated_set_saturates_and_reports_it() {
	tmp := os.join_path(os.vtmp_dir(), 'dbc2cfg_sat_${os.getpid()}')
	os.mkdir_all(tmp)!
	defer {
		os.rmdir_all(tmp) or {}
	}
	dbc := os.join_path(tmp, 'bus.dbc')
	os.write_file(dbc, 'VERSION ""
BO_ 256 Frame: 8 ECU
 SG_ Pct : 0|8@1+ (1,0) [0|100] "%" ECU
 SG_ Temp : 8|8@1+ (0.5,-40) [-40|87.5] "C" ECU
 SG_ Torque : 16|16@1- (0.1,0) [-3276.8|3276.7] "Nm" ECU
 SG_ Grid : 32|8@1+ (0.1,0) [0|10.03] "" ECU
 SG_ Moto : 47|12@0+ (1,0) [0|0] "" ECU
BO_ 257 Wide: 8 ECU
 SG_ Big : 0|64@1+ (1,0) [0|0] "" ECU
VAL_ 256 Pct 255 "SNA" ;
')!
	out := os.join_path(tmp, 'dbc_gen.v')
	tool := os.join_path(tmp, 'dbc2cfg')
	build := os.execute('${@VEXE} -path "@vlib|@vmodules|${@VMODROOT}" -o ${tool} ${os.join_path(@VMODROOT,
		'tools', 'dbc2cfg')}')
	assert build.exit_code == 0, build.output
	gen := os.execute('${tool} ${dbc} ${out}')
	assert gen.exit_code == 0, gen.output
	os.write_file(os.join_path(tmp, 'sat_test.v'), "module gen

import math

struct Sent {
	raw u64
	sat bool
}

fn pct(x f64) Sent {
	mut d := [64]u8{}
	sat := frame_pct_set(mut d, x)
	return Sent{frame_pct_raw(d), sat}
}

fn temp(x f64) Sent {
	mut d := [64]u8{}
	sat := frame_temp_set(mut d, x)
	return Sent{frame_temp_raw(d), sat}
}

fn torque(x f64) Sent {
	mut d := [64]u8{}
	sat := frame_torque_set(mut d, x)
	return Sent{frame_torque_raw(d), sat}
}

fn grid(x f64) Sent {
	mut d := [64]u8{}
	sat := frame_grid_set(mut d, x)
	return Sent{frame_grid_raw(d), sat}
}

fn moto(x f64) Sent {
	mut d := [64]u8{}
	sat := frame_moto_set(mut d, x)
	return Sent{frame_moto_raw(d), sat}
}

fn big(x f64) Sent {
	mut d := [64]u8{}
	sat := wide_big_set(mut d, x)
	return Sent{wide_big_raw(d), sat}
}

fn test_unsigned_range() {
	assert pct(42) == Sent{42, false}
	assert pct(100) == Sent{100, false}
	assert pct(150) == Sent{100, true} // fits 8 bits, but not [0|100]
	assert pct(300) == Sent{100, true} // used to wrap to 44
	assert pct(-1) == Sent{0, true} // used to wrap to 255
	assert pct(255) == Sent{255, false} // VAL_ 255 \"SNA\": named, so sent as itself
	assert pct(254) == Sent{100, true}
}

fn test_offset_and_factor_at_the_ends() {
	assert temp(-40) == Sent{0, false}
	assert temp(87.5) == Sent{255, false}
	assert temp(87.74) == Sent{255, false} // rounds onto the end
	assert temp(87.75) == Sent{255, true} // rounds past it
	assert temp(-40.24) == Sent{0, false}
	assert temp(-40.25) == Sent{0, true}
	mut d := [64]u8{}
	d[1] = 0xFF
	assert frame_temp_phys(d) == 87.5
}

fn test_signed_and_scaled() {
	assert torque(-3276.8) == Sent{0x8000, false}
	assert torque(3276.7) == Sent{0x7FFF, false}
	assert torque(-3276.85) == Sent{0x8000, true}
	assert torque(3276.75) == Sent{0x7FFF, true}
	assert torque(-0.1) == Sent{0xFFFF, false}
}

fn test_an_end_off_the_grid() {
	assert grid(10.03) == Sent{100, false}
	assert grid(10.04) == Sent{100, false}
	assert grid(10.05) == Sent{100, true}
}

fn test_no_declared_range_is_the_width() {
	assert moto(4095) == Sent{4095, false}
	assert moto(4096) == Sent{4095, true}
	assert big(1.8446744073709552e19) == Sent{~u64(0), false} // 2^64 - 1 in f64: the top itself
	assert big(1e30) == Sent{~u64(0), true}
	assert big(1e19) == Sent{10000000000000000000, false}
}

fn test_infinities_and_not_a_number() {
	assert pct(math.inf(1)) == Sent{100, true}
	assert torque(math.inf(-1)) == Sent{0x8000, true}
	nan := math.nan()
	assert pct(nan) == Sent{0, true}
	assert torque(nan) == Sent{0, true}
}
")!
	// the test file alone (V compiles the module's other files beside it): `v test` would hand the
	// -path on to a shell unquoted
	r := os.execute('${@VEXE} -enable-globals -path "@vlib|@vmodules|${@VMODROOT}" ${os.join_path(tmp,
		'sat_test.v')}')
	assert r.exit_code == 0, r.output
}
