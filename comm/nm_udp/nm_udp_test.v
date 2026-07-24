module nm_udp

import comm.nm

fn test_udp_nm_binding() {
	mut node_a := nm.Nm{
		cfg: nm.Timings{
			msg_cycle_us:  100_000
			timeout_us:    500_000
			repeat_us:     200_000
			wait_sleep_us: 100_000
		}
	}
	mut node_b := nm.Nm{
		cfg: nm.Timings{
			msg_cycle_us:  100_000
			timeout_us:    500_000
			repeat_us:     200_000
			wait_sleep_us: 100_000
		}
	}

	bind_a := new_udp_binding(0x01, 0x05, 30490)
	bind_b := new_udp_binding(0x02, 0x0A, 30490)

	assert bind_a.port == 30490
	assert bind_b.port == 30490

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
