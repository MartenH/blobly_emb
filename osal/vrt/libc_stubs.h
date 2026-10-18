/* libc_stubs.h — the C library calls V's runtime names on a -freestanding image, defined here
 * (vrt_d_freestanding.v #includes it into the one generated translation unit). newlib's own would
 * link what they depend on: its exit the stdio teardown (fflush, and so _write, _read, _lseek and
 * _close, which do not exist here — the link warns that they "will always fail"), its setenv the
 * allocator. The target has no environment and never exits. Written in C, not V, because their
 * parameters are const char * and an exported V function cannot say const. */
#ifndef BLOBLY_VRT_LIBC_STUBS_H
#define BLOBLY_VRT_LIBC_STUBS_H

#include <stdlib.h>

/* exit stops the image where it is, as bare_panic does: a debugger finds it, a watchdog resets */
void exit(int status) {
	(void)status;
	for (;;) {
	}
}

char *getenv(const char *name) {
	(void)name;
	return 0;
}

int setenv(const char *name, const char *value, int overwrite) {
	(void)name;
	(void)value;
	(void)overwrite;
	return -1;
}

#endif
