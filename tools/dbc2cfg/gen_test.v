module main

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
