module bcrypto

// SHA-512 (FIPS 180-4), no-alloc, streaming. The boot manager hashes an image
// in flash-read-sized chunks (update), so this is a context, not one-shot only.
// Verified against the FIPS/RFC 6234 known-answer vectors in sha512_test.v.
//
// Constant tables are fixed-array literal consts (fold to rodata, like
// comm/secoc's sbox) — NOT computed, so they never touch _vinit. The build's
// scripts/lint_vinit.sh guards this if it ever regresses on a freestanding
// image.

const sha512_h0 = [u64(0x6a09e667f3bcc908), 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b,
	0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b,
	0x5be0cd19137e2179]!

const sha512_k = [u64(0x428a2f98d728ae22), 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f,
	0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b,
	0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c,
	0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
	0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5,
	0x240ca1cc77ac9c65, 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4,
	0x76f988da831153b5, 0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f,
	0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f,
	0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
	0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6,
	0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791,
	0xc76c51a30654be30, 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a,
	0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99,
	0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
	0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72,
	0x8cc702081a6439ec, 0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915,
	0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e,
	0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae,
	0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
	0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec,
	0x6c44198c4a475817]!

pub struct Sha512 {
mut:
	state  [8]u64
	buf    [128]u8
	buflen int
	total  u64 // message length in bytes (128-bit spec; images << 2^64, hi = 0)
}

@[inline]
fn ror64(x u64, n int) u64 {
	return (x >> u64(n)) | (x << u64(64 - n))
}

// new_sha512 returns a fresh context seeded with the FIPS initial hash values.
pub fn new_sha512() Sha512 {
	mut c := Sha512{}
	for i in 0 .. 8 {
		c.state[i] = sha512_h0[i]
	}
	return c
}

fn (mut c Sha512) block(p &u8) {
	mut w := [80]u64{}
	for t in 0 .. 16 {
		b := t * 8
		unsafe {
			w[t] = (u64(p[b]) << 56) | (u64(p[b + 1]) << 48) | (u64(p[b + 2]) << 40) | (u64(p[
				b + 3]) << 32) | (u64(p[b + 4]) << 24) | (u64(p[b + 5]) << 16) | (u64(p[b + 6]) << 8) | u64(p[
				b + 7])
		}
	}
	for t in 16 .. 80 {
		s0 := ror64(w[t - 15], 1) ^ ror64(w[t - 15], 8) ^ (w[t - 15] >> 7)
		s1 := ror64(w[t - 2], 19) ^ ror64(w[t - 2], 61) ^ (w[t - 2] >> 6)
		w[t] = w[t - 16] + s0 + w[t - 7] + s1
	}
	mut a := c.state[0]
	mut b := c.state[1]
	mut cc := c.state[2]
	mut d := c.state[3]
	mut e := c.state[4]
	mut f := c.state[5]
	mut g := c.state[6]
	mut h := c.state[7]
	for t in 0 .. 80 {
		big1 := ror64(e, 14) ^ ror64(e, 18) ^ ror64(e, 41)
		ch := (e & f) ^ ((~e) & g)
		t1 := h + big1 + ch + sha512_k[t] + w[t]
		big0 := ror64(a, 28) ^ ror64(a, 34) ^ ror64(a, 39)
		maj := (a & b) ^ (a & cc) ^ (b & cc)
		t2 := big0 + maj
		h = g
		g = f
		f = e
		e = d + t1
		d = cc
		cc = b
		b = a
		a = t1 + t2
	}
	c.state[0] += a
	c.state[1] += b
	c.state[2] += cc
	c.state[3] += d
	c.state[4] += e
	c.state[5] += f
	c.state[6] += g
	c.state[7] += h
}

// update absorbs n bytes.
pub fn (mut c Sha512) update(data &u8, n int) {
	mut off := 0
	c.total += u64(n)
	// fill a partial buffer first
	if c.buflen > 0 {
		for off < n && c.buflen < 128 {
			c.buf[c.buflen] = unsafe { data[off] }
			c.buflen++
			off++
		}
		if c.buflen == 128 {
			c.block(&c.buf[0])
			c.buflen = 0
		}
	}
	for n - off >= 128 {
		c.block(unsafe { &data[off] })
		off += 128
	}
	for off < n {
		c.buf[c.buflen] = unsafe { data[off] }
		c.buflen++
		off++
	}
}

// final pads per FIPS 180-4 and returns the 64-byte digest. The context is
// consumed (do not update after final).
pub fn (mut c Sha512) final() [64]u8 {
	bitlen := c.total * 8
	// 0x80 then zeros to leave 16 bytes for the 128-bit length
	c.buf[c.buflen] = 0x80
	c.buflen++
	if c.buflen > 112 {
		for c.buflen < 128 {
			c.buf[c.buflen] = 0
			c.buflen++
		}
		c.block(&c.buf[0])
		c.buflen = 0
	}
	for c.buflen < 112 {
		c.buf[c.buflen] = 0
		c.buflen++
	}
	// 128-bit big-endian length: high 64 bits are 0 for our sizes
	for i in 0 .. 8 {
		c.buf[112 + i] = 0
	}
	for i in 0 .. 8 {
		c.buf[120 + i] = u8(bitlen >> u64((7 - i) * 8))
	}
	c.block(&c.buf[0])
	mut out := [64]u8{}
	for i in 0 .. 8 {
		v := c.state[i]
		for j in 0 .. 8 {
			out[i * 8 + j] = u8(v >> u64((7 - j) * 8))
		}
	}
	return out
}

// sum512 is the one-shot digest of data[0..n].
pub fn sum512(data &u8, n int) [64]u8 {
	mut c := new_sha512()
	c.update(data, n)
	return c.final()
}
