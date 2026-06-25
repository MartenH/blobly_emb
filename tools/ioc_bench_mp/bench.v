// ioc_bench_mp — like ioc_bench, but writer and reader run in SEPARATE forked
// PROCESSES (one per core), sharing only the mmap'd IOC region. This is the AMP
// model a multicore OS-on-Linux uses, and the foundation a per-process ThreadX
// instance sits on. Proves the lock-free IOC works cross-process, not just
// cross-thread.
//
//   v -gc none run tools/ioc_bench_mp/bench.v
module main

import osal

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

// shared scratch layout: [0]=writer ops, [1]=reader ops, [2]=tear count
const sc_writes = 0
const sc_reads = 1
const sc_tears = 2

fn fill(mut r Rec, n u64) {
	r.seq = n
	r.a = u32(n)
	r.b = u32(n) * 2 + 1
	r.c = u32(n) * 3 + 2
	r.pad[0] = u8(n)
}

fn consistent(r Rec) bool {
	return r.a == u32(r.seq) && r.b == u32(r.seq) * 2 + 1 && r.c == u32(r.seq) * 3 + 2
		&& r.pad[0] == u8(r.seq)
}

fn scratch() &u64 {
	return unsafe { &u64(osal.shared_scratch()) }
}

fn writer_entry(_ int, _ voidptr) {
	mut r := Rec{}
	deadline := osal.now_us() + run_us
	mut n := u64(0)
	for osal.now_us() < deadline {
		n++
		fill(mut r, n)
		osal.ioc_publish(ch, &r, u8(sizeof(r)))
	}
	mut sc := scratch()
	unsafe {
		sc[sc_writes] = n
	}
}

fn reader_entry(_ int, _ voidptr) {
	mut r := Rec{}
	deadline := osal.now_us() + run_us
	mut n := u64(0)
	mut tear := u64(0)
	for osal.now_us() < deadline {
		if osal.ioc_acquire(ch, &r, u8(sizeof(r))) && !consistent(r) {
			tear++
		}
		n++
	}
	mut sc := scratch()
	unsafe {
		sc[sc_reads] = n
		sc[sc_tears] = tear
	}
}

fn main() {
	osal.ioc_shared_init() // MUST be before any start_core (fork)
	pid_w := osal.start_core(0, writer_entry, unsafe { nil })
	pid_r := osal.start_core(1, reader_entry, unsafe { nil })
	osal.wait_core(pid_w)
	osal.wait_core(pid_r)

	mut sc := scratch()
	w := unsafe { sc[sc_writes] }
	rd := unsafe { sc[sc_reads] }
	tear := unsafe { sc[sc_tears] }
	rns := f64(run_us * 1000) / f64(rd)
	println('multi-process IOC (fork per core + MAP_SHARED), ${sizeof(Rec)}B record, 1s:')
	println('  writer (core0, pid ${pid_w}): ${w:14} ops')
	println('  reader (core1, pid ${pid_r}): ${rd:14} ops  (${rns:6.2} ns/op)  torn=${tear}')
}
