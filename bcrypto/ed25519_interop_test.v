module bcrypto

// @verifies REQ-BOOT-017
// Cross-check the no-alloc port against V's stdlib crypto.ed25519 (a heap-based
// port of Go's — usable on the HOST only, which is why the target needs our
// port). Ed25519 is deterministic, so a correct signer is byte-identical: we
// sign with the stdlib and (a) verify with ours, (b) assert our signature
// equals theirs. This is a HOST-only test; it never enters a target build.
import crypto.ed25519 as std

fn test_interop_against_stdlib() {
	for t in 0 .. 24 {
		mut seed := [32]u8{}
		for i in 0 .. 32 {
			seed[i] = u8((t * 37 + i * 5 + 1) & 0xff)
		}
		mut msg := []u8{len: (t * 111) % 900}
		for i in 0 .. msg.len {
			msg[i] = u8((t * 7 + i * 3 + 2) & 0xff)
		}

		// stdlib: derive key + sign from the same 32-byte seed
		std_priv := std.new_key_from_seed(seed[..].clone())
		std_pub := std_priv[32..].clone()
		std_sig := std.sign(std_priv, msg) or {
			assert false, 'stdlib sign failed'
			return
		}

		// our public key + signature must match the stdlib byte-for-byte
		our_pub := public_key(seed)
		for i in 0 .. 32 {
			assert our_pub[i] == std_pub[i], 'pubkey mismatch at ${i} (t=${t})'
		}
		our_sig := sign(seed, msg)
		for i in 0 .. 64 {
			assert our_sig[i] == std_sig[i], 'sig mismatch at ${i} (t=${t})'
		}

		// and OUR verify accepts the stdlib-produced signature
		mut pk := [32]u8{}
		mut sg := [64]u8{}
		for i in 0 .. 32 {
			pk[i] = std_pub[i]
		}
		for i in 0 .. 64 {
			sg[i] = std_sig[i]
		}
		assert verify(pk, msg, sg), 'our verify rejected a stdlib signature (t=${t})'
	}
}
