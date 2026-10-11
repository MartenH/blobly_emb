module vrt

// V3's builtin calls these on a `-freestanding` image and declares them without defining
// them (its `-bare-builtin-dir`, which would supply them, is not implemented). Exported by
// their C names, so the generated C links against them; written in V, so `bare_panic` and
// `bare_backtrace` take and return V's own `string`.

// bare_print / bare_eprint: the target has no console, so V's print output is dropped
@[export: 'bare_print']
fn bare_print(buf &u8, len u64) {
}

@[export: 'bare_eprint']
fn bare_eprint(buf &u8, len u64) {
}

// bare_panic stops the image where it is, as a fault does on these boards (Default_Handler,
// __tx_BadHandler): a debugger finds it here, and an enabled watchdog resets it
@[export: 'bare_panic']
fn bare_panic(msg string) {
	for {}
}

@[export: 'bare_backtrace']
fn bare_backtrace() string {
	return ''
}

// __malloc: there is no heap on target (docs/no-alloc.md), so an allocation fails and V's own
// out-of-memory path panics
@[export: '__malloc']
fn bare_malloc(n usize) voidptr {
	return unsafe { nil }
}
