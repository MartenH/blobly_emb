// ioc_bench — measure the lock-free IOC under concurrent cross-core access with
// a NON-SCALAR record, and check for torn reads. Writer on core 0, reader on
// core 1. Compares the seqlock (write/read) and triple-buffer (publish/acquire)
// variants. Reports ns/op and tear count (must be 0 = consistent snapshots).
//
//   v -prod run tools/ioc_bench/bench.v
module main

import osal

// A non-scalar signal record (~64 B): multiple fields that must stay mutually
// consistent. The reader checks the cross-field invariant to detect tearing.
struct Rec {
mut:
	seq u64
	a   u32
	b   u32
	c   u32
	pad [40]u8
}

const ch = 0
const run_us = u64(1_000_000)

// transport under test
enum Tx {
	seqlock // 1x memory, reader may retry
	double  // 2x memory, wait-free, tear-free if reader keeps up
	triple  // 3x memory, wait-free, always tear-free
}

fn fill(mut r Rec, n u64) {
	r.seq = n
	r.a = u32(n)
	r.b = u32(n) * 2 + 1
	r.c = u32(n) * 3 + 2
	r.pad[0] = u8(n)
}

// consistent reports whether a read record is internally coherent (not torn).
fn consistent(r Rec) bool {
	return r.a == u32(r.seq) && r.b == u32(r.seq) * 2 + 1 && r.c == u32(r.seq) * 3 + 2
		&& r.pad[0] == u8(r.seq)
}

struct Res {
	ops  u64
	tear u64
}

fn run(tx Tx, pace_us u64) Res {
	wt := spawn fn (tx Tx, pace_us u64) u64 {
		osal.pin_to_core(0)
		mut r := Rec{}
		deadline := osal.now_us() + run_us
		mut n := u64(0)
		for osal.now_us() < deadline {
			n++
			fill(mut r, n)
			match tx {
				.seqlock { osal.ioc_write(ch, &r, u8(sizeof(r))) }
				.double { osal.ioc_publish2(ch, &r, u8(sizeof(r))) }
				.triple { osal.ioc_publish(ch, &r, u8(sizeof(r))) }
			}
			if pace_us > 0 {
				osal.sleep_us(pace_us) // periodic writer, like a real signal cycle
			}
		}
		return n
	}(tx, pace_us)

	rt := spawn fn (tx Tx) Res {
		osal.pin_to_core(1)
		mut r := Rec{}
		deadline := osal.now_us() + run_us
		mut n := u64(0)
		mut tear := u64(0)
		for osal.now_us() < deadline {
			got := match tx {
				.seqlock { osal.ioc_read(ch, &r, u8(sizeof(r))) }
				.double { osal.ioc_acquire2(ch, &r, u8(sizeof(r))) }
				.triple { osal.ioc_acquire(ch, &r, u8(sizeof(r))) }
			}
			if got && !consistent(r) {
				tear++
			}
			n++
		}
		return Res{n, tear}
	}(tx)

	wt.wait()
	rr := rt.wait()
	return rr
}

fn report(name string, r Res) {
	ns := f64(run_us * 1000) / f64(r.ops)
	println('  ${name:-12}: ${r.ops:12} reads  (${ns:6.2} ns/op)  torn=${r.tear}')
}

fn main() {
	println('IOC non-scalar (${sizeof(Rec)} B record), 2 pinned cores, 1s/side:')
	println(' saturated writer (worst case):')
	report('seqlock 1x', run(.seqlock, 0))
	report('double 2x', run(.double, 0))
	report('triple 3x', run(.triple, 0))
	println(' paced writer @100us (realistic "signals at intervals"):')
	report('seqlock 1x', run(.seqlock, 100))
	report('double 2x', run(.double, 100))
	report('triple 3x', run(.triple, 100))
}
