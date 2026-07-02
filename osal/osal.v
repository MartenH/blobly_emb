module osal

// OS Abstraction Layer. The comms stack, Loom and apps depend only on this —
// never on the kernel directly. Host/sim backend: POSIX + native shim. Target:
// ThreadX (SMP) with MPU-backed partitions.

#flag -I @VMODROOT/osal
#flag @VMODROOT/osal/osal_native.c
#flag @VMODROOT/osal/osal_threadx.c
#flag -pthread
#include <time.h>
#include "osal_native.h"

struct C.timespec {
	tv_sec  i64
	tv_nsec i64
}

fn C.clock_gettime(int, &C.timespec) int
fn C.nanosleep(&C.timespec, &C.timespec) int
fn C.blob_pin_to_cpu(int)
fn C.blob_ioc_shared_init()
fn C.blob_shared_scratch() voidptr
fn C.blob_start_core(int, fn (int, voidptr), voidptr) int
fn C.blob_wait_core(int) int
fn C.blob_tx_start_core(int, fn (int, voidptr), voidptr) int // ThreadX backend
fn C.blob_tx_sleep_us(u64)
fn C.blob_ioc_write(int, &u8, u8)
fn C.blob_ioc_read(int, &u8, u8) int
fn C.blob_ioc_pub(int, &u8, u8)
fn C.blob_ioc_acq(int, &u8, u8) int
fn C.blob_ioc_pub2(int, &u8, u8)
fn C.blob_ioc_acq2(int, &u8, u8) int

const clock_monotonic = 1 // Linux CLOCK_MONOTONIC

// now_us returns a monotonic timestamp in microseconds.
pub fn now_us() u64 {
	ts := C.timespec{}
	C.clock_gettime(clock_monotonic, &ts)
	return u64(ts.tv_sec) * 1_000_000 + u64(ts.tv_nsec) / 1000
}

pub fn sleep_us(us u64) {
	$if threadx ? {
		C.blob_tx_sleep_us(us) // yield via the ThreadX scheduler
	} $else {
		ts := C.timespec{
			tv_sec:  i64(us / 1_000_000)
			tv_nsec: i64((us % 1_000_000) * 1000)
		}
		C.nanosleep(&ts, unsafe { nil })
	}
}

// pin_to_core binds the calling partition's thread to a physical core (AMP).
pub fn pin_to_core(core int) {
	C.blob_pin_to_cpu(core)
}

// --- Multi-process AMP: one process per core, sharing only the IOC region ---

pub type CoreEntry = fn (core int, arg voidptr)

// ioc_shared_init places the IOC region in shared memory. Call ONCE, before any
// start_core, so every per-core process sees the same channels.
pub fn ioc_shared_init() {
	C.blob_ioc_shared_init()
}

// start_core forks a process pinned to `core` and runs `entry` there; returns
// the child pid to the parent. The host-Linux model of an AMP core (fork +
// MAP_SHARED). Under `-d threadx` the child enters a per-core ThreadX kernel and
// runs `entry` as a ThreadX thread; otherwise it runs `entry` directly (POSIX).
pub fn start_core(core int, entry CoreEntry, arg voidptr) int {
	$if threadx ? {
		return C.blob_tx_start_core(core, entry, arg)
	} $else {
		return C.blob_start_core(core, entry, arg)
	}
}

pub fn wait_core(pid int) int {
	return C.blob_wait_core(pid)
}

// shared_scratch returns a pointer to a small shared-memory scratch area
// (16 u64s) usable across the per-core processes.
pub fn shared_scratch() voidptr {
	return C.blob_shared_scratch()
}

// scratch_slots is the number of u64 cells in the shared scratch area.
pub const scratch_slots = 16

// scratch_set / scratch_get: store/load a u64 in the shared scratch (slot 0..15).
// An aligned 64-bit access is single-copy atomic, so these are safe for low-rate
// cross-core telemetry (one writer per slot) — e.g. per-partition processor load —
// without a full IOC channel. Out-of-band from the signal channels.
pub fn scratch_set(slot int, v u64) {
	if slot < 0 || slot >= scratch_slots {
		return
	}
	unsafe {
		p := &u64(C.blob_shared_scratch())
		p[slot] = v
	}
}

pub fn scratch_get(slot int) u64 {
	if slot < 0 || slot >= scratch_slots {
		return 0
	}
	p := &u64(C.blob_shared_scratch())
	return unsafe { p[slot] }
}

// --- IOC: the only memory shared between partitions (last-is-best mailbox) ---

// ioc_write publishes a value to a channel. On target this region is MPU-guarded
// so only the owning partition may write.
pub fn ioc_write(idx int, src voidptr, len u8) {
	C.blob_ioc_write(idx, unsafe { &u8(src) }, len)
}

// ioc_read returns the latest value on a channel; false if nothing was ever
// written (so a reader treats an unwritten channel as "no data / invalid").
pub fn ioc_read(idx int, dst voidptr, max_len u8) bool {
	return C.blob_ioc_read(idx, unsafe { &u8(dst) }, max_len) != 0
}

// ioc_publish / ioc_acquire: lock-free triple-buffer variant. Wait-free for both
// sides (never retries) for arbitrary non-scalar payloads, at 3x memory. Use for
// readers that must never spin; otherwise prefer ioc_write/ioc_read.
pub fn ioc_publish(idx int, src voidptr, len u8) {
	C.blob_ioc_pub(idx, unsafe { &u8(src) }, len)
}

pub fn ioc_acquire(idx int, dst voidptr, max_len u8) bool {
	return C.blob_ioc_acq(idx, unsafe { &u8(dst) }, max_len) != 0
}

// ioc_publish2 / ioc_acquire2: double-buffer variant (2x memory). Wait-free both
// sides; tear-free when the reader keeps up with the write interval. The
// memory-conscious choice when 3x SRAM is too costly.
pub fn ioc_publish2(idx int, src voidptr, len u8) {
	C.blob_ioc_pub2(idx, unsafe { &u8(src) }, len)
}

pub fn ioc_acquire2(idx int, dst voidptr, max_len u8) bool {
	return C.blob_ioc_acq2(idx, unsafe { &u8(dst) }, max_len) != 0
}
