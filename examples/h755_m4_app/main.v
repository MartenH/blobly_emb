module main

// h755_m4_app — ThreadX + a Loom FB on the H755's Cortex-M4 (multicore rungs 4+5,
// hand-written precursor of the multi-image codegen, exactly as threadx_h735 was for the
// M7 path). The CM7 owns the bus and all bring-up; this core parks until clocks-ready
// (duo.h), then runs TWO threads:
//   m4_app  (prio 11): loom.Scheduler dispatching app.M4Load.on_10ms — the FB — whose
//           result publishes cross-core on IOC slot 0 {n, acc}.
//   stress  (prio 12): max-rate IOC writes on slot 1 {n, n*K} + the heartbeat — the
//           tear-detection channel the CM7's `iocx` shell command validates against.
import loom
import app

fn C.duo_wait_clocks()
fn C.board_timebase_init()
fn C.board_now_us() u64
fn C.duo_ioc_init()
fn C.duo_pub(int, u32, u32)
fn C.duo_hb_bump()
fn C._tx_initialize_kernel_enter()
fn C._tx_thread_create(voidptr, &char, fn (u32), u32, voidptr, u32, u32, u32, u32, u32) u32
fn C._tx_thread_sleep(u32) u32

__global (
	g_app_tcb      [32]u64 // >= sizeof(TX_THREAD) (200 B), 8-byte aligned
	g_app_stack    [4096]u8
	g_stress_tcb   [32]u64
	g_stress_stack [1024]u8
	g_sched        loom.Scheduler // module-sized: bss, never an entry-frame local
)

struct AppState {
mut:
	load app.M4Load
}

fn handler_m4load_on_10ms(ctx voidptr) {
	mut st := unsafe { &AppState(ctx) }
	acc := st.load.next()
	C.duo_pub(0, st.load.n, acc) // cross-core: the M7's `m4sig` reads this
}

fn run_app() {
	mut st := AppState{} // small + carries the FB field defaults: stack is right
	mut sched := &g_sched
	sched.every(10000, handler_m4load_on_10ms, &st)
	for {
		sched.run(C.board_now_us())
		C._tx_thread_sleep(u32(1))
	}
}

fn app_thread_entry(input u32) {
	run_app()
}

// stress floods IOC slot 1 with {n, n*K} as fast as the core goes (preempted each tick by
// the FB thread) — every read the M7 makes must satisfy b == a*K or the cross-core triple
// buffer tore. Also carries the rung-3 heartbeat, so the `cm4` command stays meaningful.
fn stress_thread_entry(input u32) {
	mut n := u32(0)
	for {
		n++
		C.duo_pub(1, n, n * 2654435761)
		C.duo_hb_bump()
	}
}

@[export: 'tx_application_define']
fn tx_application_define(first_unused voidptr) {
	C._tx_thread_create(&g_app_tcb[0], c'm4_app', app_thread_entry, u32(0), &g_app_stack[0],
		u32(g_app_stack.len), u32(11), u32(11), u32(0), u32(1))
	C._tx_thread_create(&g_stress_tcb[0], c'm4_stress', stress_thread_entry, u32(0),
		&g_stress_stack[0], u32(g_stress_stack.len), u32(12), u32(12), u32(0), u32(1))
}

fn main() {
	C.duo_wait_clocks() // park until the CM7's PLL is up: SysTick assumes the final HCLK
	C.board_timebase_init()
	C.duo_ioc_init()
	C._tx_initialize_kernel_enter() // never returns
}
