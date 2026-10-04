module uds

// RemoteReset is a server's bookkeeping for requests that reach it over the network (DoIP) beside
// its bus — the ONE rule the application's server (comm/diag Connection) and the bootloader's
// (boot.Prog) both keep:
//   - a network request is in flight until its answer — or DoIP's acknowledgement of it, when there
//     is none — has been acknowledged by the tester: no reset overtakes it (`inflight`);
//   - a reset asked over the network is the network's: a bus answer that is lost does not cancel it
//     (`reset`);
//   - a connection that drops cancels the network's reset only while that reset's answer is
//     unacknowledged. TCP acknowledges in order, so the acknowledgement of any later answer covers
//     it, and a request pipelined behind it whose connection drops takes nothing with it.
// No field defaults: zero is nothing in flight and no reset.
pub struct RemoteReset {
pub mut:
	inflight bool
	reset    bool // the pending reset was asked over the network
	acked    bool // ... and its answer has been acknowledged
}

// begin: a network request is taken (answered or not: its acknowledgement goes out)
pub fn (mut r RemoteReset) begin() {
	r.inflight = true
}

// asked: the request just served left a reset pending; `remote`: it came over the network
pub fn (mut r RemoteReset) asked(remote bool) {
	r.reset = remote
	r.acked = false
}

// sent: the answer to the network request served last has been acknowledged
pub fn (mut r RemoteReset) sent() {
	r.inflight = false
	if r.reset {
		r.acked = true
	}
}

// dropped: the network connection is gone. True when the pending reset must be cancelled: asked
// over it, its answer never acknowledged.
pub fn (mut r RemoteReset) dropped() bool {
	r.inflight = false
	return r.reset && !r.acked
}
