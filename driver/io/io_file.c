/* Host / sim backend: file mirror (docs/io.md sim story).
 *
 * Every point mirrors to io/<name> under the current working directory: a
 * shell/GUI pokes inputs (via tools/ioset) and watches outputs with zero
 * target hardware. Updates in BOTH directions use write-then-rename
 * (io/.<name>.drv.tmp -> io/<name>, atomic on POSIX), so no reader ever
 * observes a truncated value from a conforming writer. A non-conforming
 * writer (a bare `echo >`) can still expose a partial or empty file; the
 * reader keeps the LAST-GOOD value on any open/parse failure — the sim's
 * documented cost of file transparency, and exactly the latest-complete-
 * sample contract (REQ-IO-003). Reads are one open/read/close, no retry
 * loops — bounded work, wait-free by contract (REQ-IO-008). */
#include "io_port.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>

#define BLOB_IO_MAX 32

static struct {
	char name[64];
	char pin[16]; /* informational on host; the pin-table key on target */
	int dir;      /* 0=in 1=out */
	unsigned int init;
	unsigned int last; /* last-good value, served on any read failure */
	int configured;
} g_pt[BLOB_IO_MAX];

static void pt_path(char *buf, size_t n, const char *name) {
	snprintf(buf, n, "io/%s", name);
}

/* write-then-rename: the sim's atomic update protocol (docs/io.md). The io
 * thread's own output writes use it too, so a GUI/test reading an actuator
 * file never observes a truncated value. The tmp name is driver-distinct
 * (.name.drv.tmp) so a concurrent tools/ioset (.name.tmp) can't collide.
 * excl = seed semantics: link() never replaces — a value a supplier raced
 * in stays (rename would clobber it). Returns 0=ok, -1=failed. */
static int pt_write_file(const char *name, int level, int excl) {
	char tmp[128], path[128];
	snprintf(tmp, sizeof(tmp), "io/.%s.drv.tmp", name);
	pt_path(path, sizeof(path), name);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0) return -1;
	const char *v = level ? "1\n" : "0\n";
	ssize_t n = write(fd, v, 2);
	close(fd);
	if (n != 2) { unlink(tmp); return -1; }
	if (excl) {
		int r = link(tmp, path);
		int e = errno;
		unlink(tmp);
		return (r == 0 || e == EEXIST) ? 0 : -1;
	}
	if (rename(tmp, path) < 0) { unlink(tmp); return -1; }
	return 0;
}

int blob_io_cfg(int ch, const char *name, const char *pin, int dir, unsigned int init_val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !name || !pin) return -1;
	strncpy(g_pt[ch].name, name, sizeof(g_pt[ch].name) - 1);
	g_pt[ch].name[sizeof(g_pt[ch].name) - 1] = '\0';
	strncpy(g_pt[ch].pin, pin, sizeof(g_pt[ch].pin) - 1);
	g_pt[ch].pin[sizeof(g_pt[ch].pin) - 1] = '\0';
	g_pt[ch].dir = dir;
	g_pt[ch].init = init_val;
	g_pt[ch].last = init_val;
	g_pt[ch].configured = 1;
	return 0;
}

int blob_io_init(void) {
	/* EEXIST alone is not enough: "io" as a regular FILE also reports EEXIST —
	 * verify it is a directory, or every mirror write below fails. */
	if (mkdir("io", 0777) < 0) {
		if (errno != EEXIST) return -1;
		struct stat st;
		if (stat("io", &st) < 0 || !S_ISDIR(st.st_mode)) return -1;
	}
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (!g_pt[i].configured) continue;
		if (g_pt[i].dir) {
			/* output: establish the configured init level FIRST, before any
			 * app runs (REQ-IO-009) — the file-mirror twin of configuring the
			 * output register before muxing the pin. An output whose init
			 * cannot be established is a failed init, not a hope. */
			if (pt_write_file(g_pt[i].name, g_pt[i].init ? 1 : 0, 0) < 0) return -1;
		} else {
			/* input: seed the file with init unless a supplier beat us to it
			 * (excl: never replace a raced-in value), then load the initial
			 * last-good. Seed failure is not fatal — the boot read_checked
			 * path reports it as a startup fault instead. */
			pt_write_file(g_pt[i].name, g_pt[i].init ? 1 : 0, 1);
			g_pt[i].last = (unsigned int)blob_io_gpio_read(i);
		}
	}
	return 0;
}

/* parse one complete value from the mirror file. 0 = real value in *val,
 * -1 = unreadable/unparsable — missing, empty, garbage, or TRAILING garbage
 * ("1garbage" is not a value a conforming writer produced). One open/read/
 * close, no retries: bounded work (REQ-IO-008). */
static int pt_read_file(int ch, int *val) {
	char path[128], buf[32];
	pt_path(path, sizeof(path), g_pt[ch].name);
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) return -1;
	buf[n] = '\0';
	char *end = NULL;
	long v = strtol(buf, &end, 10);
	if (end == buf) return -1;
	while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r') end++;
	if (*end != '\0') return -1; /* trailing garbage: not a value */
	*val = v != 0 ? 1 : 0;
	return 0;
}

int blob_io_gpio_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return 0;
	int v;
	/* any failure serves last-good; the next poll heals it (REQ-IO-003). */
	if (pt_read_file(ch, &v) < 0) return (int)g_pt[ch].last;
	g_pt[ch].last = (unsigned int)v;
	return v;
}

int blob_io_gpio_read_checked(int ch, int *val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || !val) return -1;
	/* NO last-good fallback: the boot publish must not fabricate a sample —
	 * on failure the caller publishes nothing and counts a startup fault. */
	if (pt_read_file(ch, val) < 0) return -1;
	g_pt[ch].last = (unsigned int)*val;
	return 0;
}

void blob_io_gpio_write(int ch, int level) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return;
	pt_write_file(g_pt[ch].name, level ? 1 : 0, 0);
	g_pt[ch].last = level ? 1u : 0u;
}

void blob_io_close(void) {
	for (int i = 0; i < BLOB_IO_MAX; i++)
		g_pt[i].configured = 0;
}
