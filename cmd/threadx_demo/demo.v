// Backend harness: a self-contained FB (inline) running on the OSAL backend
// across two AMP partitions. Same V source builds on POSIX (make demo) or
// ThreadX (make demo-threadx). Independent of any example so it always builds.
module main

import osal
import loom

const ch_speed = 0
const ch_over = 1
const ch_ctrl = 2
const ch_result = 3

struct FilteredSpeed {
mut:
	kph   u16
	valid bool
}

struct Overspeed {
mut:
	active bool
}

struct Ctrl {
mut:
	stop u8
}

struct Result {
mut:
	first_on int
	on_count u32
}

// A minimal FB: overspeed threshold.
struct OverspeedDetector {
mut:
	active bool
}

fn (mut fb OverspeedDetector) on_10ms(inp FilteredSpeed) Overspeed {
	fb.active = inp.valid && inp.kph > 120
	return Overspeed{
		active: fb.active
	}
}

struct AppState {
mut:
	det OverspeedDetector
}

fn app_tick(ctx voidptr) {
	mut st := unsafe { &AppState(ctx) }
	mut speed := FilteredSpeed{}
	osal.ioc_acquire(ch_speed, &speed, u8(sizeof(speed)))
	mut over := st.det.on_10ms(speed)
	osal.ioc_publish(ch_over, &over, u8(sizeof(over)))
}

fn partition_app(_ int, _ voidptr) {
	mut st := AppState{}
	mut sched := loom.Scheduler{}
	sched.every(10_000, app_tick, &st)
	for {
		sched.run(osal.now_us())
		mut c := Ctrl{}
		if osal.ioc_acquire(ch_ctrl, &c, u8(sizeof(c))) && c.stop != 0 {
			break
		}
		osal.sleep_us(5000)
	}
}

fn partition_io(_ int, _ voidptr) {
	mut first_on := -1
	mut on_count := 0
	for cycle in 0 .. 30 {
		mut fs := FilteredSpeed{
			kph:   u16(cycle * 10)
			valid: true
		}
		osal.ioc_publish(ch_speed, &fs, u8(sizeof(fs)))
		osal.sleep_us(30000)
		mut ov := Overspeed{}
		if osal.ioc_acquire(ch_over, &ov, u8(sizeof(ov))) && ov.active {
			on_count++
			if first_on < 0 {
				first_on = cycle * 10
			}
		}
	}
	mut res := Result{
		first_on: first_on
		on_count: u32(on_count)
	}
	osal.ioc_publish(ch_result, &res, u8(sizeof(res)))
	mut c := Ctrl{
		stop: 1
	}
	osal.ioc_publish(ch_ctrl, &c, u8(sizeof(c)))
}

fn main() {
	osal.ioc_shared_init()
	backend := $if threadx ? { 'ThreadX' } $else { 'POSIX' }
	println('OverspeedDetector FB on ${backend} AMP (real Loom, inline FB):')
	pid_io := osal.start_core(0, partition_io, unsafe { nil })
	pid_app := osal.start_core(1, partition_app, unsafe { nil })
	osal.wait_core(pid_io)
	osal.wait_core(pid_app)
	mut res := Result{
		first_on: -1
	}
	osal.ioc_acquire(ch_result, &res, u8(sizeof(res)))
	println('  overspeed first active at kph=${res.first_on} (expect 130 = first >120), count=${res.on_count}')
}
