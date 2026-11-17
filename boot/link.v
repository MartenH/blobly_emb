module boot

import comm.isotp

// LinkCfg is the node's [isotp] as gen/boot_gen.h states it to the bootloader (BOOT_BS, BOOT_STMIN,
// BOOT_TX_DL): the flow control it grants and the frame length it answers with. Every field is
// required, so the boot image (boot/target/main.v) cannot leave one out and answer at a frame length
// other than the application's (REQ-CAN-TP-026).
pub struct LinkCfg {
pub:
	bs    u8 @[required]
	stmin u8 @[required]
	tx_dl u8 @[required]
}

// configure gives the bootloader's ISO-TP link the protocol timers every owner runs with (N_Bs,
// N_Cr, N_Ar, WFTmax — field defaults are _vinit work, which a freestanding image never runs) and the
// node's flow control and frame length, so its answers go out as the application's do.
pub fn (c LinkCfg) configure(mut l isotp.Link) {
	l.init_defaults()
	l.bs = c.bs
	l.stmin = c.stmin
	l.tx_dl = c.tx_dl
}
