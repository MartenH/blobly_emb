module bcrypto

// Ed25519 (RFC 8032) — a faithful port of TweetNaCl (D. Bernstein et al.,
// public domain), whose field is 16 × i64 limbs radix 2^16, so it needs no
// u128 (which V lacks). Function names/structure mirror the reference so this
// is auditable line-for-line against tweetnacl.c. Verified against the RFC 8032
// test vectors + negative cases in ed25519_test.v (REQ-BOOT-017).
//
// On the target ONLY verify() runs; sign()/public_key() are host release
// tooling (the private key never touches the ECU — REQ-BOOT-011).

type Gf = [16]i64

const gf0 = [i64(0), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]!

const gf1 = [i64(1), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]!

const gfd = [i64(0x78a3), 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898,
	0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203]!

const gfd2 = [i64(0xf159), 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130,
	0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406]!

const gfx = [i64(0xd51a), 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c,
	0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169]!

const gfy = [i64(0x6658), 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
	0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666]!

const gfi = [i64(0xa0b0), 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7,
	0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83]!

// the group order L (little-endian bytes), for reduce/modL
const ed_l = [i64(0xed), 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2,
	0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]!

fn set25519(mut r Gf, a Gf) {
	for i in 0 .. 16 {
		r[i] = a[i]
	}
}

fn car25519(mut o Gf) {
	for i in 0 .. 16 {
		o[i] += i64(1) << 16
		c := o[i] >> 16
		if i < 15 {
			o[i + 1] += c - 1
		} else {
			o[0] += 38 * (c - 1)
		}
		o[i] -= c << 16
	}
}

fn sel25519(mut p Gf, mut q Gf, b i64) {
	c := ~(b - 1)
	for i in 0 .. 16 {
		t := c & (p[i] ^ q[i])
		p[i] ^= t
		q[i] ^= t
	}
}

fn pack25519(mut o [32]u8, n Gf) {
	mut t := Gf([16]i64{})
	mut m := Gf([16]i64{})
	set25519(mut t, n)
	car25519(mut t)
	car25519(mut t)
	car25519(mut t)
	for _ in 0 .. 2 {
		m[0] = t[0] - 0xffed
		for i := 1; i < 15; i++ {
			m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
			m[i - 1] &= 0xffff
		}
		m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
		b := (m[15] >> 16) & 1
		m[14] &= 0xffff
		sel25519(mut t, mut m, 1 - b)
	}
	for i in 0 .. 16 {
		o[2 * i] = u8(t[i] & 0xff)
		o[2 * i + 1] = u8(t[i] >> 8)
	}
}

fn unpack25519(mut o Gf, n &u8) {
	for i in 0 .. 16 {
		o[i] = i64(unsafe { n[2 * i] }) + (i64(unsafe { n[2 * i + 1] }) << 8)
	}
	o[15] &= 0x7fff
}

fn a_gf(mut o Gf, a Gf, b Gf) {
	for i in 0 .. 16 {
		o[i] = a[i] + b[i]
	}
}

fn z_gf(mut o Gf, a Gf, b Gf) {
	for i in 0 .. 16 {
		o[i] = a[i] - b[i]
	}
}

fn m_gf(mut o Gf, a Gf, b Gf) {
	mut t := [31]i64{}
	for i in 0 .. 16 {
		for j in 0 .. 16 {
			t[i + j] += a[i] * b[j]
		}
	}
	for i in 0 .. 15 {
		t[i] += 38 * t[i + 16]
	}
	for i in 0 .. 16 {
		o[i] = t[i]
	}
	car25519(mut o)
	car25519(mut o)
}

fn s_gf(mut o Gf, a Gf) {
	m_gf(mut o, a, a)
}

fn inv25519(mut o Gf, i Gf) {
	mut c := Gf([16]i64{})
	set25519(mut c, i)
	for a := 253; a >= 0; a-- {
		s_gf(mut c, c)
		if a != 2 && a != 4 {
			m_gf(mut c, c, i)
		}
	}
	set25519(mut o, c)
}

fn pow2523(mut o Gf, i Gf) {
	mut c := Gf([16]i64{})
	set25519(mut c, i)
	for a := 250; a >= 0; a-- {
		s_gf(mut c, c)
		if a != 1 {
			m_gf(mut c, c, i)
		}
	}
	set25519(mut o, c)
}

// vn: constant-time compare of n bytes — 0 if equal, -1 if any differ.
fn vn(x &u8, y &u8, n int) int {
	mut d := u32(0)
	for i in 0 .. n {
		d |= u32(unsafe { x[i] } ^ unsafe { y[i] })
	}
	return int((1 & ((u64(d) - 1) >> 8))) - 1
}

fn crypto_verify_32(x &u8, y &u8) int {
	return vn(x, y, 32)
}

fn neq25519(a Gf, b Gf) int {
	mut c := [32]u8{}
	mut d := [32]u8{}
	pack25519(mut c, a)
	pack25519(mut d, b)
	return crypto_verify_32(&c[0], &d[0])
}

fn par25519(a Gf) u8 {
	mut d := [32]u8{}
	pack25519(mut d, a)
	return d[0] & 1
}

// A point is [4]Gf = {X, Y, Z, T} in extended twisted-Edwards coordinates.
fn add_pt(mut p [4]Gf, q [4]Gf) {
	mut a := Gf([16]i64{})
	mut b := Gf([16]i64{})
	mut c := Gf([16]i64{})
	mut d := Gf([16]i64{})
	mut t := Gf([16]i64{})
	mut e := Gf([16]i64{})
	mut f := Gf([16]i64{})
	mut g := Gf([16]i64{})
	mut h := Gf([16]i64{})
	z_gf(mut a, p[1], p[0])
	z_gf(mut t, q[1], q[0])
	m_gf(mut a, a, t)
	a_gf(mut b, p[0], p[1])
	a_gf(mut t, q[0], q[1])
	m_gf(mut b, b, t)
	m_gf(mut c, p[3], q[3])
	m_gf(mut c, c, gfd2)
	m_gf(mut d, p[2], q[2])
	a_gf(mut d, d, d)
	z_gf(mut e, b, a)
	z_gf(mut f, d, c)
	a_gf(mut g, d, c)
	a_gf(mut h, b, a)
	m_gf(mut p[0], e, f)
	m_gf(mut p[1], h, g)
	m_gf(mut p[2], g, f)
	m_gf(mut p[3], e, h)
}

fn cswap_pt(mut p [4]Gf, mut q [4]Gf, b u8) {
	for i in 0 .. 4 {
		sel25519(mut p[i], mut q[i], i64(b))
	}
}

fn scalarmult(mut p [4]Gf, mut q [4]Gf, s &u8) {
	set25519(mut p[0], gf0)
	set25519(mut p[1], gf1)
	set25519(mut p[2], gf1)
	set25519(mut p[3], gf0)
	for i := 255; i >= 0; i-- {
		b := u8((unsafe { s[i / 8] } >> u8(i & 7)) & 1)
		cswap_pt(mut p, mut q, b)
		add_pt(mut q, p)
		add_pt(mut p, p)
		cswap_pt(mut p, mut q, b)
	}
}

fn scalarbase(mut p [4]Gf, s &u8) {
	mut q := [4]Gf{}
	set25519(mut q[0], gfx)
	set25519(mut q[1], gfy)
	set25519(mut q[2], gf1)
	m_gf(mut q[3], gfx, gfy)
	scalarmult(mut p, mut q, s)
}

fn unpackneg(mut r [4]Gf, pk &u8) int {
	mut t := Gf([16]i64{})
	mut chk := Gf([16]i64{})
	mut num := Gf([16]i64{})
	mut den := Gf([16]i64{})
	mut den2 := Gf([16]i64{})
	mut den4 := Gf([16]i64{})
	mut den6 := Gf([16]i64{})
	set25519(mut r[2], gf1)
	unpack25519(mut r[1], pk)
	s_gf(mut num, r[1])
	m_gf(mut den, num, gfd)
	z_gf(mut num, num, r[2])
	a_gf(mut den, r[2], den)
	s_gf(mut den2, den)
	s_gf(mut den4, den2)
	m_gf(mut den6, den4, den2)
	m_gf(mut t, den6, num)
	m_gf(mut t, t, den)
	pow2523(mut t, t)
	m_gf(mut t, t, num)
	m_gf(mut t, t, den)
	m_gf(mut t, t, den)
	m_gf(mut r[0], t, den)
	s_gf(mut chk, r[0])
	m_gf(mut chk, chk, den)
	if neq25519(chk, num) != 0 {
		m_gf(mut r[0], r[0], gfi)
	}
	s_gf(mut chk, r[0])
	m_gf(mut chk, chk, den)
	if neq25519(chk, num) != 0 {
		return -1
	}
	if par25519(r[0]) == (unsafe { pk[31] } >> 7) {
		z_gf(mut r[0], gf0, r[0])
	}
	m_gf(mut r[3], r[0], r[1])
	return 0
}

// modL reduces the 64-limb x mod L into the low 32 bytes of r. No-alloc: fixed
// arrays throughout — the on-target verify path must not touch a heap the boot
// does not have.
fn modl(mut r [32]u8, mut x [64]i64) {
	mut carry := i64(0)
	for i := 63; i >= 32; i-- {
		carry = 0
		mut j := i - 32
		for ; j < i - 12; j++ {
			x[j] += carry - 16 * x[i] * ed_l[j - (i - 32)]
			carry = (x[j] + 128) >> 8
			x[j] -= carry << 8
		}
		x[j] += carry
		x[i] = 0
	}
	carry = 0
	for j in 0 .. 32 {
		x[j] += carry - (x[31] >> 4) * ed_l[j]
		carry = x[j] >> 8
		x[j] &= 255
	}
	for j in 0 .. 32 {
		x[j] -= carry * ed_l[j]
	}
	for i in 0 .. 32 {
		x[i + 1] += x[i] >> 8
		r[i] = u8(x[i] & 255)
	}
}

// reduce_scalar reduces a 64-byte little-endian hash mod L to a 32-byte scalar.
fn reduce_scalar(digest [64]u8) [32]u8 {
	mut x := [64]i64{}
	for i in 0 .. 64 {
		x[i] = i64(digest[i])
	}
	mut r := [32]u8{}
	modl(mut r, mut x)
	return r
}

// s_canonical reports S < L for the signature's S half (sig[32..64], little-endian).
fn s_canonical(sig [64]u8) bool {
	for i := 31; i >= 0; i-- {
		sb := int(sig[32 + i])
		lb := int(ed_l[i])
		if sb < lb {
			return true
		}
		if sb > lb {
			return false
		}
	}
	return false // S == L is also non-canonical
}

// Verifier streams the message for verify (the boot hashes an image from flash
// in chunks — there is no RAM to buffer it). Usage:
//   mut v := verify_start(pubkey, sig)
//   v.update(chunk, n) ...            // the signed message, in any pieces
//   ok := v.finish()
pub struct Verifier {
mut:
	q       [4]Gf   // the unpacked -A point
	hc      Sha512  // hashing R ‖ A ‖ M
	sig     [64]u8
	key_ok  bool
}

// verify_start unpacks the public key and seeds the hash with R ‖ A. If the key
// is not a curve point, finish() will return false regardless of the message.
pub fn verify_start(pubkey [32]u8, sig [64]u8) Verifier {
	mut v := Verifier{
		sig: sig
	}
	v.key_ok = unpackneg(mut v.q, &pubkey[0]) == 0
	v.hc = new_sha512()
	v.hc.update(&sig[0], 32) // R
	v.hc.update(&pubkey[0], 32) // A
	return v
}

pub fn (mut v Verifier) update(data &u8, n int) {
	v.hc.update(data, n)
}

pub fn (mut v Verifier) finish() bool {
	if !v.key_ok {
		return false
	}
	// RFC 8032 §8.4: reject non-canonical S (S >= L) — anti-malleability. TweetNaCl
	// omits this; a secure-boot verifier must not. Compare sig[32..64] (LE) < L.
	if !s_canonical(v.sig) {
		return false
	}
	digest := v.hc.final()
	mut h := reduce_scalar(digest)
	mut p := [4]Gf{}
	scalarmult(mut p, mut v.q, unsafe { &h[0] }) // p = [h](-A)
	mut sb := [4]Gf{}
	mut s := [32]u8{}
	for i in 0 .. 32 {
		s[i] = v.sig[32 + i]
	}
	scalarbase(mut sb, unsafe { &s[0] }) // sb = [S]B
	add_pt(mut p, sb) // p = [S]B - [h]A
	mut packed := [32]u8{}
	pack_point(mut packed, p) // encode, normalising by Z
	return crypto_verify_32(&v.sig[0], &packed[0]) == 0
}

// verify returns true iff sig is a valid Ed25519 signature of msg under pubkey.
pub fn verify(pubkey [32]u8, msg []u8, sig [64]u8) bool {
	mut v := verify_start(pubkey, sig)
	if msg.len > 0 {
		v.update(&msg[0], msg.len)
	}
	return v.finish()
}

// pack_point encodes a point [4]Gf to its 32-byte form (y ‖ sign(x)).
fn pack_point(mut r [32]u8, p [4]Gf) {
	mut tx := Gf([16]i64{})
	mut ty := Gf([16]i64{})
	mut zi := Gf([16]i64{})
	inv25519(mut zi, p[2])
	m_gf(mut tx, p[0], zi)
	m_gf(mut ty, p[1], zi)
	pack25519(mut r, ty)
	r[31] ^= par25519(tx) << 7
}

// ---- host-side signing (release tooling; never on the target) ----

// public_key derives the 32-byte Ed25519 public key from a 32-byte seed.
pub fn public_key(seed [32]u8) [32]u8 {
	mut d := sum512(&seed[0], 32)
	d[0] &= 248
	d[31] &= 127
	d[31] |= 64
	mut p := [4]Gf{}
	scalarbase(mut p, &d[0])
	mut pk := [32]u8{}
	pack_point(mut pk, p)
	return pk
}

// sign produces the 64-byte Ed25519 signature of msg under a 32-byte seed.
pub fn sign(seed [32]u8, msg []u8) [64]u8 {
	mut d := sum512(&seed[0], 32)
	d[0] &= 248
	d[31] &= 127
	d[31] |= 64
	pk := public_key(seed)
	// r = SHA512(prefix ‖ M) mod L
	mut rc := new_sha512()
	rc.update(&d[32], 32) // prefix = d[32..64]
	if msg.len > 0 {
		rc.update(&msg[0], msg.len)
	}
	rdig := rc.final()
	mut rr := reduce_scalar(rdig) // r mod L
	mut p := [4]Gf{}
	scalarbase(mut p, unsafe { &rr[0] }) // R = [r]B
	mut sig := [64]u8{}
	mut renc := [32]u8{}
	pack_point(mut renc, p)
	for i in 0 .. 32 {
		sig[i] = renc[i]
	}
	// k = SHA512(R ‖ A ‖ M) mod L
	mut kc := new_sha512()
	kc.update(&sig[0], 32)
	kc.update(&pk[0], 32)
	if msg.len > 0 {
		kc.update(&msg[0], msg.len)
	}
	kdig := kc.final()
	h := reduce_scalar(kdig) // k mod L
	// S = (r + k·a) mod L
	mut x := [64]i64{}
	for i in 0 .. 32 {
		x[i] = i64(rr[i])
	}
	for i in 0 .. 32 {
		for j in 0 .. 32 {
			x[i + j] += i64(h[i]) * i64(d[j])
		}
	}
	mut sbytes := [32]u8{}
	modl(mut sbytes, mut x)
	for i in 0 .. 32 {
		sig[32 + i] = sbytes[i]
	}
	return sig
}
