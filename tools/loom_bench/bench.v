// loom_bench — measure the Loom scheduler's dispatch overhead: time per run()
// scan and per handler invocation, for a few static-table sizes. Pure framework
// cost (handlers do a trivial increment), single core, no IOC. Complements the
// ioc_bench transport numbers: this is the "scheduler tax" per tick.
//
//   v -prod run tools/loom_bench/bench.v
module main

import osal
import loom

const iters = u64(2_000_000)

fn tick(ctx voidptr) {
	mut c := unsafe { &u64(ctx) }
	unsafe {
		*c = *c + 1
	}
}

// All `n` handlers fire every run (period 1us, time advances 1us per run), so we
// measure scan + dispatch. ns/run is the per-tick cost with n handlers; ns/dispatch
// is the marginal cost of one handler invocation.
fn bench(n int) {
	mut sched := loom.Scheduler{}
	mut counters := [32]u64{}
	for i in 0 .. n {
		sched.every(1, tick, &counters[i])
	}
	mut now := u64(0)
	start := osal.now_us()
	for _ in 0 .. iters {
		sched.run(now)
		now += 1
	}
	elapsed_ns := f64((osal.now_us() - start) * 1000)

	mut total := u64(0)
	for i in 0 .. n {
		total += counters[i]
	}
	if total != iters * u64(n) {
		println('  WARN: ${n} handlers fired ${total}, expected ${iters * u64(n)}')
	}
	ns_run := elapsed_ns / f64(iters)
	ns_disp := elapsed_ns / (f64(iters) * f64(n))
	println('  ${n:2} handlers: ${ns_run:7.2} ns/run   ${ns_disp:6.2} ns/dispatch')
}

fn main() {
	osal.pin_to_core(0)
	println('Loom dispatch overhead (${iters} runs, 1 core, all handlers due each run):')
	bench(1)
	bench(4)
	bench(8)
	bench(32)
}
