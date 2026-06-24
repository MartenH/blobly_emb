// The real blobly app on the ThreadX OSAL backend.
//
// Uses the ACTUAL loom.Scheduler + app.SpeedMonitor (not a C reimplementation),
// across two AMP partitions launched via osal.start_core, exchanging signals
// through the IOC. Build:
//   v -o blobly_demo cmd/threadx_demo          # POSIX backend (fork per core)
//   make demo-threadx THREADX=/path/to/threadx  # ThreadX backend (-d threadx)
// Same V code, two backends — that's the point of the OSAL seam.
module main

import app
import loom
import osal

const ioc_speed = 0  // IO  -> App: VehicleSpeed
const ioc_lamp = 1   // App -> IO:  WarnLamp
const ioc_ctrl = 2   // IO  -> App: lifecycle (stop)
const ioc_result = 3 // IO  -> main: demo result

struct Ctrl {
mut:
	stop u8
}

struct Result {
mut:
	first_on int
	on_count u32
}

// ---- App partition (core 1): the real component on the real Loom ----
struct AppState {
mut:
	mon app.SpeedMonitor
}

fn app_tick(ctx voidptr) {
	mut st := unsafe { &AppState(ctx) }
	mut speed := app.VehicleSpeed{}
	osal.ioc_acquire(ioc_speed, &speed, u8(sizeof(speed)))
	mut lamp := app.WarnLamp{}
	st.mon.on_10ms(speed, mut lamp) // the actual SpeedMonitor handler
	osal.ioc_publish(ioc_lamp, &lamp, u8(sizeof(lamp)))
}

fn partition_app(core int, arg voidptr) {
	mut st := AppState{}
	mut sched := loom.Scheduler{}
	sched.every(10_000, app_tick, &st)
	for {
		sched.run(osal.now_us())
		mut c := Ctrl{}
		if osal.ioc_acquire(ioc_ctrl, &c, u8(sizeof(c))) && c.stop != 0 {
			break
		}
		osal.sleep_us(5000)
	}
}

// ---- IO partition (core 0): stimulus + observer ----
fn partition_io(core int, arg voidptr) {
	mut first_on := -1
	mut on_count := 0
	for cycle in 0 .. 30 {
		mut vs := app.VehicleSpeed{
			kph:   u16(cycle * 10)
			valid: true
		}
		osal.ioc_publish(ioc_speed, &vs, u8(sizeof(vs)))
		osal.sleep_us(30000) // let the App partition's Loom process this speed
		mut lamp := app.WarnLamp{}
		if osal.ioc_acquire(ioc_lamp, &lamp, u8(sizeof(lamp))) && lamp.on {
			on_count++
			if first_on < 0 {
				first_on = cycle * 10
			}
		}
	}
	// publish the result, then stop the App partition — both over IOC.
	mut res := Result{
		first_on: first_on
		on_count: u32(on_count)
	}
	osal.ioc_publish(ioc_result, &res, u8(sizeof(res)))
	mut c := Ctrl{
		stop: 1
	}
	osal.ioc_publish(ioc_ctrl, &c, u8(sizeof(c)))
}

fn main() {
	osal.ioc_shared_init() // shared IOC region BEFORE fork
	backend := $if threadx ? { 'ThreadX' } $else { 'POSIX' }
	println('blobly SpeedMonitor on ${backend} AMP (real Loom + app.SpeedMonitor):')

	pid_io := osal.start_core(0, partition_io, unsafe { nil })
	pid_app := osal.start_core(1, partition_app, unsafe { nil })
	osal.wait_core(pid_io)
	osal.wait_core(pid_app)

	mut res := Result{
		first_on: -1
	}
	osal.ioc_acquire(ioc_result, &res, u8(sizeof(res))) // result over IOC, not scratch
	println('  lamp first ON at kph=${res.first_on} (expect 130 = first >120), on_count=${res.on_count}')
}
