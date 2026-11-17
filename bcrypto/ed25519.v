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
		o[i] -= c * 65536
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

// ed25519_mults: the field multiplications m_gf ran, counted in a test build only — what the test
// holds each VerifyJob unit's charge against (declared only there: a tool importing bcrypto builds
// without -enable-globals)
$if test {
	__global ed25519_mults u64
}

fn m_gf(mut o Gf, a Gf, b Gf) {
	$if test {
		ed25519_mults++
	}
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

// exp_bit: one bit of a fixed exponentiation by square-and-multiply — inv25519's (bits 253..0,
// multiplying unless inv_mul says not) and pow2523's (bits 250..0, pow_mul); VerifyJob runs them a
// bit at a time
fn exp_bit(mut c Gf, base Gf, mul bool) {
	s_gf(mut c, c)
	if mul {
		m_gf(mut c, c, base)
	}
}

fn inv_mul(a int) bool {
	return a != 2 && a != 4
}

fn pow_mul(a int) bool {
	return a != 1
}

fn inv25519(mut o Gf, i Gf) {
	mut c := Gf([16]i64{})
	set25519(mut c, i)
	for a := 253; a >= 0; a-- {
		exp_bit(mut c, i, inv_mul(a))
	}
	set25519(mut o, c)
}

fn pow2523(mut o Gf, i Gf) {
	mut c := Gf([16]i64{})
	set25519(mut c, i)
	for a := 250; a >= 0; a-- {
		exp_bit(mut c, i, pow_mul(a))
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
	d2 := gfd2 // a local: V emits a const as C const, which no `Gf` parameter takes
	m_gf(mut c, c, d2)
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

// scalarmult_init: p = the neutral point, where a scalar multiplication starts
fn scalarmult_init(mut p [4]Gf) {
	zero, one := gf0, gf1
	set25519(mut p[0], zero)
	set25519(mut p[1], one)
	set25519(mut p[2], one)
	set25519(mut p[3], zero)
}

// scalarmult_bit: bit i of the ladder (bits 255..0 in turn) — two point additions
fn scalarmult_bit(mut p [4]Gf, mut q [4]Gf, s &u8, i int) {
	b := u8((unsafe { s[i / 8] } >> u8(i & 7)) & 1)
	cswap_pt(mut p, mut q, b)
	add_pt(mut q, p)
	add_pt(mut p, p)
	cswap_pt(mut p, mut q, b)
}

fn scalarmult(mut p [4]Gf, mut q [4]Gf, s &u8) {
	scalarmult_init(mut p)
	for i := 255; i >= 0; i-- {
		scalarmult_bit(mut p, mut q, s, i)
	}
}

// base_point: q = B
fn base_point(mut q [4]Gf) {
	x, y, one := gfx, gfy, gf1
	set25519(mut q[0], x)
	set25519(mut q[1], y)
	set25519(mut q[2], one)
	m_gf(mut q[3], x, y)
}

fn scalarbase(mut p [4]Gf, s &u8) {
	mut q := [4]Gf{}
	base_point(mut q)
	scalarmult(mut p, mut q, s)
}

fn unpackneg(mut r [4]Gf, pk &u8) int {
	mut t := Gf([16]i64{})
	mut num := Gf([16]i64{})
	mut den := Gf([16]i64{})
	unpack_pre(mut r, pk, mut num, mut den, mut t)
	pow2523(mut t, t)
	return unpack_post(mut r, pk, num, den, t)
}

// unpack_pre: unpackneg up to its exponentiation — r's Y and Z, num, den, and t, pow2523's base
fn unpack_pre(mut r [4]Gf, pk &u8, mut num Gf, mut den Gf, mut t Gf) {
	mut den2 := Gf([16]i64{})
	mut den4 := Gf([16]i64{})
	mut den6 := Gf([16]i64{})
	one := gf1
	set25519(mut r[2], one)
	unpack25519(mut r[1], pk)
	s_gf(mut num, r[1])
	d := gfd
	m_gf(mut den, num, d)
	z_gf(mut num, num, r[2])
	a_gf(mut den, r[2], den)
	s_gf(mut den2, den)
	s_gf(mut den4, den2)
	m_gf(mut den6, den4, den2)
	m_gf(mut t, den6, num)
	m_gf(mut t, t, den)
}

// unpack_post: unpackneg from pow2523's result `pw` on — 0, or -1 when pk is not a point
fn unpack_post(mut r [4]Gf, pk &u8, num Gf, den Gf, pw Gf) int {
	mut t := Gf([16]i64{})
	mut chk := Gf([16]i64{})
	set25519(mut t, pw)
	m_gf(mut t, t, num)
	m_gf(mut t, t, den)
	m_gf(mut t, t, den)
	m_gf(mut r[0], t, den)
	s_gf(mut chk, r[0])
	m_gf(mut chk, chk, den)
	if neq25519(chk, num) != 0 {
		i := gfi
		m_gf(mut r[0], r[0], i)
	}
	s_gf(mut chk, r[0])
	m_gf(mut chk, chk, den)
	if neq25519(chk, num) != 0 {
		return -1
	}
	if par25519(r[0]) == (unsafe { pk[31] } >> 7) {
		zero := gf0
		z_gf(mut r[0], zero, r[0])
	}
	m_gf(mut r[3], r[0], r[1])
	return 0
}

// is_point: `pubkey` decodes as a curve point — a key verify could ever accept. For the generator's
// check of a configured public key (tools/loom2v); verify_start asks the same question.
pub fn is_point(pubkey [32]u8) bool {
	mut q := [4]Gf{}
	return unpackneg(mut q, &pubkey[0]) == 0
}

// small_order: `pubkey` decodes to a point of small order — one the cofactor 8 takes to the neutral
// point: the neutral point itself and the points of order 2, 4 and 8, in every encoding (a y at or
// above p reduces like any other). Such a key verifies a forged proof — under the neutral point, R =
// the neutral point and S = 0 verify for every message — so a configured public key must not be one.
// Computed, not a list of encodings: decoded, doubled three times, compared with the neutral point. A
// HOST check of a configured key (tools/loom2v); the verify itself never asks it (the keys are
// constants the generator refused). A key that is no point is not small-order (is_point says so).
pub fn small_order(pubkey [32]u8) bool {
	mut p := [4]Gf{}
	if unpackneg(mut p, &pubkey[0]) != 0 {
		return false
	}
	for _ in 0 .. 3 {
		add_pt(mut p, p)
	}
	zero := gf0
	return neq25519(p[0], zero) == 0 && neq25519(p[1], p[2]) == 0
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
			x[j] -= carry * 256
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

// VerifyJob is the same verify as Verifier.finish (verify_start's key unpacking included), run a
// bounded number of FIELD MULTIPLICATIONS at a time (step), for a caller that must not stall: an
// application's 0x29 proof is verified on the comm thread, whose pass also carries the bus
// (comm/udsauth). The functions are Verifier's; only the driver differs. It holds every
// intermediate itself (about 2.8 KB), so a caller keeps one in static storage, never on a stack:
//   j.start(pubkey, sig)   // in place: the struct is too big to return
//   j.update(msg, n) ...
//   for !j.step(budget) {} // one call per pass in practice
//   ok := j.verified()
// A whole verify is about 10,300 multiplications (the key's exponentiation ~500, the two ladders
// 2 x 256 x 18, the inversion ~500).
pub struct VerifyJob {
mut:
	hc    Sha512
	sig   [64]u8
	pk    [32]u8
	q     [4]Gf // -A, moved by the first ladder
	bq    [4]Gf // B, moved by the second
	p     [4]Gf // [h](-A), then [S]B - [h]A
	sb    [4]Gf // [S]B
	num   Gf
	den   Gf
	c     Gf // an exponentiation's accumulator
	e     Gf // and its base
	h     [32]u8
	phase int
	i     int // the exponent or scalar bit next
	valid bool
}

// the phases of a VerifyJob, in order
const vj_key = 0 // unpack_pre
const vj_key_pow = 1 // pow2523, a bit at a time
const vj_key_post = 2 // unpack_post, S canonical, h
const vj_mul_h = 3 // [h](-A), a bit at a time
const vj_mul_s = 4 // [S]B, a bit at a time
const vj_inv = 5 // Z's inverse, a bit at a time, then the compare
const vj_done = 6

// A unit's cost is counted in field multiplications (m_gf: 271 64-bit multiply-accumulates and two
// carry passes). The work that is not one is charged in its equivalent, rounded up from the operation
// count and checked against a host measurement (the TweetNaCl field multiplication ~1.0 us, a SHA-512
// compression ~1.9 us, the mod-L reduction ~3.9 us, unoptimised, x86-64):
//   sha512_block_mults  a SHA-512 compression — 80 rounds and the 64-word schedule, ~2,800 64-bit
//                       additions, rotations and logic operations, two to four instructions each on
//                       a 32-bit core
//   modl_mults          the reduction mod L (modl) — 704 64-bit multiply-accumulates, its carries
//   unpack_post_mults   unpack_post's multiplications, the most it runs (its second square root
//                       branch taken)
//   pack_mults          pack25519 and the compare — three carry passes, two trial subtractions of
//                       p and 32 byte compares, less than one multiplication's carries and adds
const sha512_block_mults = 3
const modl_mults = 4
const unpack_post_mults = 10
const pack_mults = 1

// key_post_mults: vj_key_post's cost — unpack_post, then (the key a point, S canonical) the hash's
// final compressions (`blocks`, Sha512.final_blocks) and h's reduction mod L
fn key_post_mults(blocks int) int {
	return unpack_post_mults + blocks * sha512_block_mults + modl_mults
}

// verify_step_max: the multiplications in the largest single unit of work — the last bit of the
// second ladder with the point addition after it (27), above vj_key_post's at most key_post_mults(2)
// (20) — so a step costs at most budget + this - 1
pub const verify_step_max = 27

// start begins verifying `sig` under `pubkey`; then update with the message
pub fn (mut j VerifyJob) start(pubkey [32]u8, sig [64]u8) {
	j.sig = sig
	j.pk = pubkey
	j.hc = new_sha512()
	j.hc.update(&j.sig[0], 32) // R
	j.hc.update(&j.pk[0], 32) // A
	j.phase = vj_key
	j.i = 0
	j.valid = false
}

pub fn (mut j VerifyJob) update(data &u8, n int) {
	j.hc.update(data, n)
}

// step advances by units of work until `budget` field multiplications are spent (at least one
// unit; a unit is at most verify_step_max) — true once the verdict is in (verified)
pub fn (mut j VerifyJob) step(budget int) bool {
	mut spent := 0
	for j.phase != vj_done {
		spent += j.unit()
		if spent >= budget {
			break
		}
	}
	return j.phase == vj_done
}

// decided: the verdict is in
pub fn (j &VerifyJob) decided() bool {
	return j.phase == vj_done
}

// verified: decided, and the signature is valid
pub fn (j &VerifyJob) verified() bool {
	return j.phase == vj_done && j.valid
}

// unit: one unit of work; the field multiplications it cost
fn (mut j VerifyJob) unit() int {
	match j.phase {
		vj_key {
			unpack_pre(mut j.q, unsafe { &j.pk[0] }, mut j.num, mut j.den, mut j.e)
			set25519(mut j.c, j.e)
			j.i = 250
			j.phase = vj_key_pow
			return 7
		}
		vj_key_pow {
			exp_bit(mut j.c, j.e, pow_mul(j.i))
			j.i--
			if j.i < 0 {
				j.phase = vj_key_post
			}
			return 2
		}
		vj_key_post {
			// verify_start's key check, then finish's — S canonical (RFC 8032 §8.4), then h
			if unpack_post(mut j.q, unsafe { &j.pk[0] }, j.num, j.den, j.c) != 0
				|| !s_canonical(j.sig) {
				j.phase = vj_done
				return unpack_post_mults
			}
			blocks := j.hc.final_blocks()
			digest := j.hc.final()
			j.h = reduce_scalar(digest)
			scalarmult_init(mut j.p)
			j.i = 255
			j.phase = vj_mul_h
			return key_post_mults(blocks)
		}
		vj_mul_h {
			scalarmult_bit(mut j.p, mut j.q, unsafe { &j.h[0] }, j.i) // p = [h](-A)
			j.i--
			if j.i < 0 {
				base_point(mut j.bq) // one multiplication, q[3]
				scalarmult_init(mut j.sb)
				j.i = 255
				j.phase = vj_mul_s
				return 18 + 1
			}
			return 18
		}
		vj_mul_s {
			scalarmult_bit(mut j.sb, mut j.bq, unsafe { &j.sig[32] }, j.i) // sb = [S]B
			j.i--
			if j.i >= 0 {
				return 18
			}
			add_pt(mut j.p, j.sb) // p = [S]B - [h]A
			set25519(mut j.e, j.p[2])
			set25519(mut j.c, j.e)
			j.i = 253
			j.phase = vj_inv
			return 18 + 9
		}
		vj_inv {
			exp_bit(mut j.c, j.e, inv_mul(j.i))
			j.i--
			if j.i < 0 {
				mut packed := [32]u8{}
				pack_from_inv(mut packed, j.p, j.c) // encode, normalising by Z
				j.valid = crypto_verify_32(&j.sig[0], &packed[0]) == 0
				j.phase = vj_done
				return 2 + 2 + pack_mults
			}
			return 2
		}
		else {
			return 1
		}
	}
}

// pack_point encodes a point [4]Gf to its 32-byte form (y ‖ sign(x)).
fn pack_point(mut r [32]u8, p [4]Gf) {
	mut zi := Gf([16]i64{})
	inv25519(mut zi, p[2])
	pack_from_inv(mut r, p, zi)
}

// pack_from_inv: pack_point given zi, the inverse of p's Z
fn pack_from_inv(mut r [32]u8, p [4]Gf, zi Gf) {
	mut tx := Gf([16]i64{})
	mut ty := Gf([16]i64{})
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
