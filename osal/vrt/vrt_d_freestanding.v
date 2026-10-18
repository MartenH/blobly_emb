module vrt

#include "@VMODROOT/osal/vrt/libc_stubs.h"

// V3's builtin calls these on a `-freestanding` image and declares them without defining
// them (its `-bare-builtin-dir`, which would supply them, is not implemented). Exported by
// their C names, so the generated C links against them; written in V, so `bare_panic` and
// `bare_backtrace` take and return V's own `string`.

// bare_print / bare_eprint: the target has no console, so V's print output is dropped
@[export: 'bare_print']
fn bare_print(_ &u8, _ u64) {
}

@[export: 'bare_eprint']
fn bare_eprint(_ &u8, _ u64) {
}

// bare_panic stops the image where it is, as a fault does on these boards (Default_Handler,
// __tx_BadHandler): a debugger finds it here, and an enabled watchdog resets it
@[export: 'bare_panic']
fn bare_panic(_ string) {
	for {}
}

@[export: 'bare_backtrace']
fn bare_backtrace() string {
	return ''
}

// __malloc: there is no heap on target (docs/no-alloc.md), so an allocation fails and V's own
// out-of-memory path panics
@[export: '__malloc']
fn bare_malloc(_ usize) voidptr {
	return unsafe { nil }
}

// The C library's allocator, with no heap behind it. V3's panic path names malloc, realloc and
// free (it records a panic for `recover`, which a target never reaches: v_panic goes to
// bare_panic when no recover frame is open), and newlib's own malloc would pull in _sbrk and a
// heap the linker script does not give. Defined here, the image links without newlib's
// allocator; anything that does call them gets nil and V's out-of-memory panic.
@[export: 'malloc']
fn libc_malloc(_ usize) voidptr {
	return unsafe { nil }
}

@[export: 'calloc']
fn libc_calloc(_ usize, _ usize) voidptr {
	return unsafe { nil }
}

@[export: 'realloc']
fn libc_realloc(_ voidptr, _ usize) voidptr {
	return unsafe { nil }
}

@[export: 'free']
fn libc_free(_ voidptr) {
}
