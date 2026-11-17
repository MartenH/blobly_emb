module isotp

// The CAN identifiers a diagnostic connection is addressed by (ISO 15765-2 §10.3). A Link knows
// no ids — its owner matches and stamps them — so these are for the owners and the tools that
// configure them: one place says how wide an id may be and how normal fixed addressing derives
// its ids, and every reader (cfgschema, ecumodel, loom2v, sysmodel, sysgen) asks it.
//
// Two addressing formats are supported: normal addressing, the ids given as they are, on 11-bit
// identifiers or (`[isotp] ext = true`) on 29-bit ones; and normal fixed addressing, 29-bit ids
// derived from two one-byte addresses. Extended and mixed addressing (an address byte in the
// payload) are not.

// std_id_max is the largest 11-bit (standard) identifier.
pub const std_id_max = u32(0x7FF)

// ext_id_max is the largest 29-bit (extended) identifier.
pub const ext_id_max = u32(0x1FFF_FFFF)

// fixed_priority is the priority (the id's top three bits) a normal fixed id is sent at. ISO
// 15765-2 leaves it open; 6 is the conventional value (ISO 15765-4), and a connection compares
// its ids whole, so it takes only frames sent at this priority as its own.
pub const fixed_priority = u32(6)

// fixed_id is a normal fixed addressing identifier (ISO 15765-2 §10.3.3): priority 6, PF 0xDA for
// a physical request or answer and 0xDB for a functional request, PS the target address (N_TA)
// and the low byte the source address (N_SA) — 0x18DA<target><source>, 0x18DB<target><source>.
// A node whose own address is `sa`, talking to the tester at `ta`, therefore:
//   - receives physical requests on fixed_id(false, sa, ta)    (0x18DA<sa><ta>: to it, from the tester)
//   - sends its answers on        fixed_id(false, ta, sa)      (0x18DA<ta><sa>: to the tester, from it)
//   - receives functional requests on fixed_id(true, functional_ta, ta) (0x18DB<functional_ta><ta>)
pub fn fixed_id(functional bool, target u8, source u8) u32 {
	pf := if functional { u32(0xDB) } else { u32(0xDA) }
	return fixed_priority << 26 | pf << 16 | u32(target) << 8 | u32(source)
}
