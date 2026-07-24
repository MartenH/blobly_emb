module nm

fn test_udp_nm_binding() {
	mut node_a := Nm{
		cfg: Timings{
			msg_cycle_us:  100_000
			timeout_us:    500_000
			repeat_us:     200_000
			wait_sleep_us: 100_000
		}
	}
	mut node_b := Nm{
		cfg: Timings{
			msg_cycle_us:  100_000
			timeout_us:    500_000
			repeat_us:     200_000
			wait_sleep_us: 100_000
		}
	}

	bind_a := UdpBinding{
		node_id:  0x01
		pn_local: 0x05
	}
	bind_b := UdpBinding{
		node_id:  0x02
		pn_local: 0x0A
	}

	// Node A requests bus awake
	now := u64(1000)
	node_a.request(now)
	assert node_a.awake()

	// Node A ticks and sends UDP NM frame
	assert node_a.tick(now)
	frame_bytes := bind_a.encode(&node_a)

	// Node B receives Node A's UDP NM frame
	bind_b.process(mut node_b, now, frame_bytes)
	assert node_b.awake()
	assert node_b.pn_demanded(now, 0, bind_b.pn_local) // PN bit 0 from Node A (0x05)
}
