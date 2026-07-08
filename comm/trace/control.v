module trace

// Trace control: the lightweight command/response protocol (docs/telemetry.md — NOT
// UDS). A host sends an 8-byte TraceCmd on `cmd_id`; the target applies it to its
// TraceBuffer and replies with an 8-byte TraceRsp (ack + status) on `rsp_id`. The bulk
// buffer read-out (`dump`) is signalled back to the caller, which streams it over ISO-TP.

// Command opcodes (numbering matches docs/telemetry.md's TraceCmd table).
pub const op_arm = u8(1) // (re)arm capture from empty
pub const op_start = u8(2) // begin capturing (alias of arm)
pub const op_stop = u8(3) // stop now (freeze/full at the current fill)
pub const op_reset = u8(4) // clear + re-arm
pub const op_set_push = u8(5) // configure the unsolicited push (reserved; no-op for now)
pub const op_dump = u8(6) // stream the buffer out (caller does ISO-TP)
pub const op_status = u8(7) // just report state

// Response result codes.
pub const result_ok = u8(0)
pub const result_bad_opcode = u8(1)
pub const result_unsupported = u8(2) // a known opcode that isn't implemented yet
pub const result_not_ready = u8(3) // e.g. dump requested while still capturing
pub const result_busy = u8(4) // e.g. dump requested while a previous dump is still in flight

// Freeze cause — why capture stopped (reported in TraceRsp so a host can distinguish a
// trigger-frozen dump from a manually-stopped one; a propagated cross-core freeze reads as a
// trigger too, since every core calls trigger() on the shared freeze).
pub const freeze_none = u8(0) // still capturing / not frozen
pub const freeze_stop = u8(1) // an explicit stop (or oneshot fill)
pub const freeze_trigger = u8(2) // the overrun trigger

// Cmd is the decoded 8-byte TraceCmd.
pub struct Cmd {
pub:
	opcode         u8
	arg0           u8  // per-opcode arg (e.g. capture mode)
	period_ms      u16 // push period, for future set_push
	handler_filter u16 // 0xFFFF = all, else a handler_id
	core_mask      u16 // bit i = core i; 0 = the receiving/default core (core 0)
}

// targets reports whether this command addresses `core`. A zero mask means the single
// receiving core (core 0) so existing single-core commands, which left b6-7 zero, still
// apply to their one core.
pub fn (c Cmd) targets(core u8) bool {
	m := if c.core_mask == 0 { u16(1) } else { c.core_mask }
	return core < 16 && (m & (u16(1) << core)) != 0
}

// Rsp is the decoded 8-byte TraceRsp. `state` is the TraceBuffer.State ordinal (0 idle, 1
// capturing, 2 full, 3 frozen) in b2's low nibble; `cause` (freeze_none/_stop/_trigger) rides
// b2's high nibble — so a host reads both from the one byte without growing the frame.
pub struct Rsp {
pub:
	opcode_echo  u8
	result       u8
	state        u8
	cause        u8 // freeze cause (packed into b2's high nibble on the wire)
	records_used u16
	capacity     u16
	core         u8
}

pub fn decode_cmd(b [8]u8) Cmd {
	return Cmd{
		opcode:         b[0]
		arg0:           b[1]
		period_ms:      u16(b[2]) | (u16(b[3]) << 8)
		handler_filter: u16(b[4]) | (u16(b[5]) << 8)
		core_mask:      u16(b[6]) | (u16(b[7]) << 8)
	}
}

pub fn encode_cmd(c Cmd) [8]u8 {
	mut b := [8]u8{}
	b[0] = c.opcode
	b[1] = c.arg0
	b[2] = u8(c.period_ms)
	b[3] = u8(c.period_ms >> 8)
	b[4] = u8(c.handler_filter)
	b[5] = u8(c.handler_filter >> 8)
	b[6] = u8(c.core_mask)
	b[7] = u8(c.core_mask >> 8)
	return b
}

pub fn encode_rsp(r Rsp) [8]u8 {
	mut b := [8]u8{}
	b[0] = r.opcode_echo
	b[1] = r.result
	b[2] = (r.state & 0x0f) | (r.cause << 4) // state low nibble, freeze cause high nibble
	b[3] = u8(r.records_used)
	b[4] = u8(r.records_used >> 8)
	b[5] = u8(r.capacity)
	b[6] = u8(r.capacity >> 8)
	b[7] = r.core
	return b
}

pub fn decode_rsp(b [8]u8) Rsp {
	return Rsp{
		opcode_echo:  b[0]
		result:       b[1]
		state:        b[2] & 0x0f
		cause:        b[2] >> 4
		records_used: u16(b[3]) | (u16(b[4]) << 8)
		capacity:     u16(b[5]) | (u16(b[6]) << 8)
		core:         b[7]
	}
}

// state_code maps a TraceBuffer state to the wire ordinal.
fn state_code(s State) u8 {
	return match s {
		.idle { u8(0) }
		.capturing { u8(1) }
		.full { u8(2) }
		.frozen { u8(3) }
	}
}

// handle_cmd applies a command to the buffer and returns (the response frame bytes, a
// dump-requested flag, an addressed flag). It enforces `core_mask` here — a command that
// doesn't select `core` is ignored (no mutation, addressed = false) so targeting is
// guaranteed by the helper, not left to each caller to filter. On `dump` the caller streams
// tb's records over ISO-TP; handle_cmd itself never touches the bus, so it stays
// unit-testable and transport-agnostic.
pub fn handle_cmd(mut tb TraceBuffer, c Cmd, core u8) ([8]u8, bool, bool) {
	if !c.targets(core) {
		return [8]u8{}, false, false // not for this core: no mutation, no response
	}
	mut result := result_ok
	mut do_dump := false
	match c.opcode {
		op_arm, op_start, op_reset {
			tb.start()
		}
		op_stop {
			tb.stop() // freeze now at the current fill (not the pre/post trigger)
		}
		op_dump {
			// only a stopped buffer is safe to stream — capturing is still being written
			if tb.state() == .full || tb.state() == .frozen {
				do_dump = true
			} else {
				result = result_not_ready
			}
		}
		op_set_push {
			result = result_unsupported // push is config-driven today; runtime config TBD
		}
		op_status {}
		else {
			result = result_bad_opcode
		}
	}
	rsp := Rsp{
		opcode_echo:  c.opcode
		result:       result
		state:        state_code(tb.state())
		cause:        tb.froze_cause()
		records_used: u16(tb.used())
		capacity:     u16(tb.capacity())
		core:         core
	}
	return encode_rsp(rsp), do_dump, true
}
