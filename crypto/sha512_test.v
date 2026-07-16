module crypto

// @verifies REQ-BOOT-017
// SHA-512 against the FIPS 180-4 / RFC 6234 known-answer vectors, plus a
// streaming-vs-one-shot equivalence and the 1e6-'a' long message.

fn hexdigest(d [64]u8) string {
	hexd := '0123456789abcdef'
	mut s := []u8{len: 128}
	for i in 0 .. 64 {
		s[i * 2] = hexd[d[i] >> 4]
		s[i * 2 + 1] = hexd[d[i] & 0x0f]
	}
	return s.bytestr()
}

fn digest_of(msg string) string {
	if msg.len == 0 {
		return hexdigest(sum512(&u8(unsafe { nil }), 0))
	}
	b := msg.bytes()
	return hexdigest(sum512(&b[0], b.len))
}

fn test_sha512_empty() {
	assert digest_of('') == 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e'
}

fn test_sha512_abc() {
	assert digest_of('abc') == 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f'
}

fn test_sha512_896bit() {
	msg := 'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnojklmnopklmnopqlmnopqrmnopqrsnopqrstopqrstu'
	assert digest_of(msg) == 'd0cbb625eac6f42bc09a3579cca5d5d53068651134859ec18db81736a382bbbd0d0533b58d0917bca335524a837781ffd42c32dd6c3230f41b409a8231f99b33'
}

// exercises block boundaries + the final-pad overflow path (buflen > 112)
fn test_sha512_million_a() {
	mut c := new_sha512()
	chunk := []u8{len: 1000, init: u8(`a`)}
	for _ in 0 .. 1000 {
		c.update(&chunk[0], 1000)
	}
	assert hexdigest(c.final()) == 'e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b'
}

// streaming in odd-sized pieces must equal the one-shot digest
fn test_sha512_streaming_equiv() {
	data := []u8{len: 777, init: u8((index * 131 + 7) & 0xff)}
	oneshot := hexdigest(sum512(&data[0], data.len))
	mut c := new_sha512()
	mut off := 0
	for step in [1, 63, 64, 65, 127, 128, 129, 200] {
		mut n := step
		if off + n > data.len {
			n = data.len - off
		}
		if n > 0 {
			c.update(&data[off], n)
			off += n
		}
	}
	if off < data.len {
		c.update(&data[off], data.len - off)
	}
	assert hexdigest(c.final()) == oneshot
}
