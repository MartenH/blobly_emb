/* Host / sim backend: file mirror (docs/io.md sim story).
 *
 * Every point mirrors to io/<name> under the current working directory: a
 * shell/GUI pokes inputs (via tools/ioset) and watches outputs with zero
 * target hardware. Updates in BOTH directions use write-then-rename
 * (io/.<name>.tmp -> io/<name>, atomic on POSIX), so no reader ever
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
 * file never observes a truncated value. */
static void pt_write_file(const char *name, int level) {
	char tmp[128], path[128];
	snprintf(tmp, sizeof(tmp), "io/.%s.tmp", name);
	pt_path(path, sizeof(path), name);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0) return;
	const char *v = level ? "1\n" : "0\n";
	ssize_t n = write(fd, v, 2);
	close(fd);
	if (n != 2) { unlink(tmp); return; }
	rename(tmp, path);
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
	if (mkdir("io", 0777) < 0 && errno != EEXIST) return -1;
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (!g_pt[i].configured) continue;
		if (g_pt[i].dir) {
			/* output: establish the configured init level FIRST, before any
			 * app runs (REQ-IO-009) — the file-mirror twin of configuring the
			 * output register before muxing the pin. */
			pt_write_file(g_pt[i].name, g_pt[i].init ? 1 : 0);
		} else {
			/* input: seed the file with init only if a supplier hasn't
			 * already, then load the initial last-good from it. */
			char path[128];
			pt_path(path, sizeof(path), g_pt[i].name);
			if (access(path, F_OK) != 0)
				pt_write_file(g_pt[i].name, g_pt[i].init ? 1 : 0);
			g_pt[i].last = (unsigned int)blob_io_gpio_read(i);
		}
	}
	return 0;
}

int blob_io_gpio_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return 0;
	char path[128], buf[32];
	pt_path(path, sizeof(path), g_pt[ch].name);
	/* one open/read/close, no retries: any failure serves last-good and the
	 * next poll heals it (REQ-IO-003 / REQ-IO-008). */
	int fd = open(path, O_RDONLY);
	if (fd < 0) return (int)g_pt[ch].last;
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) return (int)g_pt[ch].last;
	buf[n] = '\0';
	char *end = NULL;
	long v = strtol(buf, &end, 10);
	if (end == buf) return (int)g_pt[ch].last; /* garbage: keep last-good */
	int level = v != 0 ? 1 : 0;
	g_pt[ch].last = (unsigned int)level;
	return level;
}

void blob_io_gpio_write(int ch, int level) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return;
	pt_write_file(g_pt[ch].name, level ? 1 : 0);
	g_pt[ch].last = level ? 1u : 0u;
}

void blob_io_close(void) {
	for (int i = 0; i < BLOB_IO_MAX; i++)
		g_pt[i].configured = 0;
}
