module main

import os
import driver.can
import osal
import loom

const lamp_frame_id = u32(0x101)

struct IoPartition {
mut:
	chan can.Channel
}

fn io_10ms(ctx voidptr) {
	mut st := unsafe { &IoPartition(ctx) }
	mut rx := can.Frame{}
	if st.chan.recv(mut rx) && rx.id == powertrain_id {
		mut vs := VehicleSpeed{
			kph:   u16(powertrain_vehicle_speed_phys(rx.data))
			valid: true
		}
		osal.ioc_publish2(vehicle_speed_ch, &vs, u8(sizeof(vs)))
	}
	mut lamp := WarnLamp{}
	if osal.ioc_acquire2(warn_lamp_ch, &lamp, u8(sizeof(lamp))) {
		mut tx := can.Frame{
			id:  lamp_frame_id
			len: 1
		}
		tx.data[0] = if lamp.on { u8(1) } else { u8(0) }
		st.chan.send(tx)
	}
}

fn partition_io(ifname string) {
	osal.pin_to_core(0)
	mut st := IoPartition{}
	if !st.chan.open(ifname, true) {
		eprintln('IO: failed to open "${ifname}" (make vcan)')
		return
	}
	mut sched := loom.Scheduler{}
	sched.every(10_000, io_10ms, &st)
	for {
		sched.run(osal.now_us())
		osal.sleep_us(1000)
	}
}

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	println('minimal example: io@c0 (bus) | app@c1 SpeedMonitor (lamp when >120 km/h)')
	t_io := spawn partition_io(ifname)
	t_app := spawn partition_app(1, unsafe { nil }) // generated
	t_io.wait()
	t_app.wait()
}
