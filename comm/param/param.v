module param

// Parameters / variant coding (docs/diagnostics.md §3.4, R7, #288), no-alloc.
//
// A parameter is a value an FB READS and never writes, fixed per vehicle rather than per build:
// coded at end of line or in the workshop with 0x2E WriteDataByIdentifier, kept in the NvM journal,
// and read back with 0x22. The FB sees it as an ordinary In field — the comm thread, the one
// writer, publishes it into the FB's input cell — so it cannot tell a parameter from a signal that
// never changes, and there is no API.
//
// One journal value per parameter, under its own block id:
//
//   [ version | schema fingerprint (2) | each field, big-endian, at its width ]
//
// The block id and the fingerprint are both derived from the parameter's LAYOUT — its name and
// its fields' names and types — so a firmware update that changes the layout finds no value it
// could misread (a pinned id keeps its block, and the fingerprint then refuses the record). The
// RANGE is not part of either: a range is not a layout, the stored bytes still mean the same thing
// under a new range, and a workshop's coding must not be lost to an update that only widens one.
// Instead every restored value is REVALIDATED against this firmware's range before an FB sees it
// (§7, R7): out of range — a range narrowed by an update — and the compiled default stands, with
// the parameter's status saying so (`reverted`), so a narrowed range is never bypassed.
//
// A write is durable before anything changes (§7, R6 / R7): the value is validated (0x13 for a
// record of the wrong length, 0x31 for a field out of range), put into the journal, and only once
// the journal has accepted it does the 0x22 record, the status, and — for `apply = next_dispatch`
// — the FB's input change. A refused put answers 0x72 generalProgrammingFailure and leaves both the
// live and the durable value exactly as they were. A write of the value the journal already holds
// writes nothing (a tester polling 0x2E with an unchanged value costs no wear).
//
// When a written value takes effect is the parameter's `apply`: `next_dispatch` — the FB's next
// dispatch after the positive answer — or `reset` — the next power-up or ECUReset, as coding that
// shapes start-up needs. Under `reset` 0x22 reads the CODED value (what the next start will apply)
// while the FB keeps the one it started with.
//
// Single-threaded: the comm thread owns the journal, the server and this table; the restore runs
// before the kernel starts. No field defaults (the _vinit rule): the owner configures every field.

import comm.uds

pub const max_params = 8 // per node: one diagnostic server
pub const max_fields = 2 // a parameter rides one {a, b} IOC cell to its FBs
pub const record_version = u8(1)
pub const record_hdr = 3 // version + fingerprint
pub const max_value = max_fields * 4
pub const max_record = record_hdr + max_value
pub const nrc_general_programming_failure = u8(0x72)

// Status, per parameter, as the status DID reports it (one byte each, declaration order).
pub const status_default = u8(0) // nothing coded: the compiled default
pub const status_coded = u8(1) // a coded value of this schema, in range, is in use
pub const status_reverted = u8(2) // a stored value was refused at restore (another schema, out of
// range, or the journal unreadable): the compiled default is in use

// Store is the journal seam: `put` replaces a block's value (false = refused, nothing changed),
// `get` reads it (its length, 0 = absent).
pub struct Store {
pub mut:
	ctx voidptr
	put fn (ctx voidptr, id u16, data &u8, len u16) bool
	get fn (ctx voidptr, id u16, out &u8, cap u16) u16
}

// Field is one field of a parameter: its width on the wire (1, 2 or 4 bytes; a bool is 1), whether
// it is signed, its inclusive range, and its compiled default (in range — generation checks it).
pub struct Field {
pub mut:
	width  u8
	signed bool
	min    i64
	max    i64
	def    i64
}

// Param is one parameter: its configuration (the generator fills it), then its state.
pub struct Param {
pub mut:
	did         u16 // the DID that codes and reads it
	id          u16 // its journal block
	fp          u16 // its layout's fingerprint, stored in the record
	nfields     int
	fields      [max_fields]Field
	apply_reset bool // the value takes effect at the next start, not the next dispatch
	// state
	stored     [max_fields]i64 // the coded value (or the default): what 0x22 reads
	has_stored bool // the journal holds a record of this schema with `stored` in it
	live       [max_fields]i64 // what the FBs read
	status     u8
}

// Params is the node's parameter table.
pub struct Params {
pub mut:
	p      [max_params]Param
	n      int
	store  Store
	// publish puts parameter i's live value into its FBs' input cell (field 0 in a, 1 in b, each as
	// its two's-complement 32 bits). Nil = no FB reads any.
	publish fn (ctx voidptr, i int, a u32, b u32)
	pub_ctx voidptr
	// the server the DIDs live in (a &uds.Server, set by bind; nil before), and the status DID's
	// index there (-1 = none declared)
	srv        voidptr
	status_idx int
	wrote      int // journal writes since the owner last asked (take_wrote)
}

// width: the record's value bytes for parameter i.
pub fn (p &Param) width() int {
	mut w := 0
	for f in 0 .. p.nfields {
		w += int(p.fields[f].width)
	}
	return w
}

// restore reads every parameter back — before the kernel starts, before any FB dispatches — and
// publishes what each FB will see. `mounted` false = the journal could not be read: every
// parameter runs on its default and says so (reverted).
pub fn (mut ps Params) restore(mounted bool) {
	for i in 0 .. ps.n {
		mut p := &ps.p[i]
		for f in 0 .. p.nfields {
			p.stored[f] = p.fields[f].def
		}
		p.has_stored = false
		p.status = status_default
		if !mounted {
			p.status = status_reverted
		} else if ps.store.get != unsafe { nil } {
			mut rec := [max_record + 1]u8{}
			// cap one past the record: an overlong stored value reads as overlong, never as ours
			n := int(ps.store.get(ps.store.ctx, p.id, &rec[0], u16(max_record + 1)))
			if n > 0 {
				p.status = status_reverted
				mut v := [max_fields]i64{}
				if n == record_hdr + p.width() && rec[0] == record_version
					&& u16(rec[1]) << 8 | u16(rec[2]) == p.fp {
					p.decode(&rec[record_hdr], mut v)
					// this schema's record, revalidated against THIS firmware's range: a value a
					// narrowed range refuses is not applied (the default stands, and says so)
					if p.in_range(v) {
						for f in 0 .. p.nfields {
							p.stored[f] = v[f]
						}
						p.has_stored = true
						p.status = status_coded
					}
				}
			}
		}
		for f in 0 .. p.nfields {
			p.live[f] = p.stored[f]
		}
		ps.publish_live(i)
	}
}

// decode reads a record's value bytes (big-endian per field) into v, sign-extending a signed field
// (a bool is a byte: its range, 0..1, refuses anything else).
fn (p &Param) decode(b &u8, mut v [max_fields]i64) {
	mut o := 0
	for f in 0 .. p.nfields {
		w := int(p.fields[f].width)
		mut raw := u64(0)
		for k in 0 .. w {
			raw = raw << 8 | u64(unsafe { b[o + k] })
		}
		o += w
		if p.fields[f].signed {
			bits := u64(8 * w)
			if raw & (u64(1) << (bits - 1)) != 0 {
				raw |= ~((u64(1) << bits) - 1)
			}
			v[f] = i64(raw)
		} else {
			v[f] = i64(raw)
		}
	}
}

// in_range: every field of v within this firmware's range.
fn (p &Param) in_range(v [max_fields]i64) bool {
	for f in 0 .. p.nfields {
		if v[f] < p.fields[f].min || v[f] > p.fields[f].max {
			return false
		}
	}
	return true
}

// encode writes v as the record's value bytes (big-endian per field) and returns their length.
fn (p &Param) encode(v [max_fields]i64, out &u8) int {
	mut o := 0
	for f in 0 .. p.nfields {
		w := int(p.fields[f].width)
		raw := u64(v[f])
		for k in 0 .. w {
			unsafe {
				out[o + k] = u8(raw >> (8 * (w - 1 - k)))
			}
		}
		o += w
	}
	return o
}

fn (ps &Params) publish_live(i int) {
	if ps.publish == unsafe { nil } {
		return
	}
	p := &ps.p[i]
	a := u32(u64(p.live[0]))
	b := if p.nfields > 1 { u32(u64(p.live[1])) } else { u32(0) }
	ps.publish(ps.pub_ctx, i, a, b)
}

// bind hands the parameters to the server: each parameter's DID record filled with its stored value
// and marked bound (0x2E goes through write), and the status DID (`status_did`, 0 = none) filled.
// After restore, on the comm thread. `s` must outlive the table (both are globals on a target).
pub fn (mut ps Params) bind(mut s uds.Server, status_did u16) {
	ps.srv = unsafe { voidptr(&s) }
	ps.status_idx = -1
	for k in 0 .. s.ndid {
		if status_did != 0 && s.dids[k].id == status_did {
			ps.status_idx = k
		}
		for i in 0 .. ps.n {
			if s.dids[k].id == ps.p[i].did {
				s.dids[k].bound = true
				s.dids[k].len = u8(ps.p[i].encode(ps.p[i].stored, &s.dids[k].data[0]))
			}
		}
	}
	ps.fill_status()
	s.did_write = uds.DidWrite{
		ctx:   unsafe { voidptr(&ps) }
		write: param_write
	}
}

fn (mut ps Params) fill_status() {
	if ps.srv == unsafe { nil } || ps.status_idx < 0 {
		return
	}
	mut srv := unsafe { &uds.Server(ps.srv) }
	mut d := &srv.dids[ps.status_idx]
	for i in 0 .. ps.n {
		d.data[i] = ps.p[i].status
	}
	d.len = u8(ps.n)
}

// find: the parameter coded through DID `did`, -1 = none.
pub fn (ps &Params) find(did u16) int {
	for i in 0 .. ps.n {
		if ps.p[i].did == did {
			return i
		}
	}
	return -1
}

// write is 0x2E on a parameter's DID, after the server's session and security gates: the NRC, 0 =
// accepted — durable, and in effect as the parameter's `apply` says. The server then stores the
// record as the DID's data, which is the coded value byte for byte.
pub fn (mut ps Params) write(did u16, data &u8, n int) u8 {
	i := ps.find(did)
	if i < 0 {
		return uds.nrc_request_out_of_range
	}
	mut p := &ps.p[i]
	if n != p.width() {
		return uds.nrc_incorrect_length
	}
	mut v := [max_fields]i64{}
	p.decode(data, mut v)
	if !p.in_range(v) {
		return uds.nrc_request_out_of_range
	}
	mut same := p.has_stored
	for f in 0 .. p.nfields {
		if v[f] != p.stored[f] {
			same = false
		}
	}
	if !same {
		if ps.store.put == unsafe { nil } {
			return nrc_general_programming_failure // nowhere durable to put it
		}
		mut rec := [max_record]u8{}
		rec[0] = record_version
		rec[1] = u8(p.fp >> 8)
		rec[2] = u8(p.fp)
		len := record_hdr + p.encode(v, &rec[record_hdr])
		if !ps.store.put(ps.store.ctx, p.id, &rec[0], u16(len)) {
			return nrc_general_programming_failure // nothing changed: live and durable as they were
		}
		ps.wrote++
		for f in 0 .. p.nfields {
			p.stored[f] = v[f]
		}
		p.has_stored = true
		p.status = status_coded
		ps.fill_status()
	}
	if !p.apply_reset {
		mut moved := false
		for f in 0 .. p.nfields {
			if p.live[f] != p.stored[f] {
				p.live[f] = p.stored[f]
				moved = true
			}
		}
		if moved {
			ps.publish_live(i)
		}
	}
	return 0
}

// take_wrote: whether a write reached the journal since the last call (an NM owner re-runs its
// sleep flush choreography for a write made in bus sleep).
pub fn (mut ps Params) take_wrote() bool {
	w := ps.wrote > 0
	ps.wrote = 0
	return w
}

fn param_write(ctx voidptr, did u16, data &u8, n int) u8 {
	mut ps := unsafe { &Params(ctx) }
	return ps.write(did, data, n)
}
