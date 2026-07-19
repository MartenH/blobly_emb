/* Host / sim backend: file mirror (docs/io.md sim story).
 *
 * Every point mirrors to io/<name> under the current working directory: a
 * shell/GUI pokes inputs (via tools/ioset) and watches outputs with zero
 * target hardware. Only OUTPUT files are driver-created (init level); an
 * input file exists only once a supplier writes it — the driver never
 * fabricates an input sample. Updates in BOTH directions use write-then-rename
 * (io/.<name>.drv.tmp -> io/<name>, atomic on POSIX), so no reader ever
 * observes a truncated value from a conforming writer. A non-conforming
 * writer (a bare `echo >`) can still expose a partial or empty file; the
 * reader keeps the LAST-GOOD value on any open/parse failure — the sim's
 * documented cost of file transparency, and exactly the latest-complete-
 * sample contract (REQ-IO-003). Reads are one open/read/close, no retry
 * loops — bounded work, wait-free by contract (REQ-IO-008).
 *
 * The mirror value is LOGICAL and kind-shaped: gpio = 0/1, adc = a converter
 * count (any u32), pwm = a duty permille (0..1000). Polarity (active_low) is a
 * pad property and never reaches the host mirror. */
#include "io_port.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>

#define BLOB_IO_MAX 32
#define IO_GPIO 0
#define IO_ADC 1
#define IO_PWM 2

static struct {
	char name[64];
	char pin[16]; /* informational on host; the pin-table key on target */
	int dir;      /* 0=in 1=out */
	int kind;     /* IO_GPIO / IO_ADC / IO_PWM */
	unsigned long adc_max; /* adc: full-scale bound (u16 65535 / u32 max) */
	unsigned int init;
	unsigned int last; /* last-good value, served on any read failure */
	int configured;
} g_pt[BLOB_IO_MAX];

static void pt_path(char *buf, size_t n, const char *name) {
	snprintf(buf, n, "io/%s", name);
}

/* write-then-rename: the sim's atomic update protocol (docs/io.md). Writes the
 * decimal value (gpio 0/1, pwm permille). Returns 0=ok, -1=failed. */
static int pt_write_value(const char *name, unsigned int val) {
	char tmp[128], path[128], v[16];
	snprintf(tmp, sizeof(tmp), "io/.%s.drv.tmp", name);
	pt_path(path, sizeof(path), name);
	int vn = snprintf(v, sizeof(v), "%u\n", val);
	if (vn <= 0 || vn >= (int)sizeof(v)) return -1;
	/* never follow a planted symlink at the tmp path: drop any stale entry,
	 * then create exclusively */
	unlink(tmp);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0666);
	if (fd < 0) return -1;
	ssize_t n = write(fd, v, (size_t)vn);
	close(fd);
	if (n != vn) { unlink(tmp); return -1; }
	/* never rename over a special file (fifo/device/dir a stray writer or
	 * attacker planted) — that is not a mirror value, it is a trap. */
	struct stat st;
	if (stat(path, &st) == 0 && !S_ISREG(st.st_mode)) { unlink(tmp); return -1; }
	if (rename(tmp, path) < 0) { unlink(tmp); return -1; }
	return 0;
}

int blob_io_cfg(int ch, const char *name, const char *pin, int dir, unsigned int init_val, int active_low, int kind, unsigned int param) {
	(void)active_low; /* the host mirror is LOGICAL by definition — polarity is a pad property */
	g_pt[ch].adc_max = (kind == IO_ADC) ? (param ? param : 0xFFFFFFFFul) : 0;
	if (ch < 0 || ch >= BLOB_IO_MAX || !name || !pin) return -1;
	strncpy(g_pt[ch].name, name, sizeof(g_pt[ch].name) - 1);
	g_pt[ch].name[sizeof(g_pt[ch].name) - 1] = '\0';
	strncpy(g_pt[ch].pin, pin, sizeof(g_pt[ch].pin) - 1);
	g_pt[ch].pin[sizeof(g_pt[ch].pin) - 1] = '\0';
	g_pt[ch].dir = dir;
	g_pt[ch].kind = kind;
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
			/* output: establish the configured init value FIRST, before any app
			 * runs (REQ-IO-009). gpio writes 0/1, pwm writes the init permille. */
			unsigned int iv = (g_pt[i].kind == IO_GPIO) ? (g_pt[i].init ? 1u : 0u) : g_pt[i].init;
			if (pt_write_value(g_pt[i].name, iv) < 0) return -1;
		}
		/* input (gpio or adc): NO file created — a driver-seeded value would be
		 * read back by the boot read_checked and published as a fabricated
		 * "real" sample. Absent file = checked read fails until a supplier
		 * writes; the periodic reads serve last-good (cfg init) meanwhile. */
	}
	return 0;
}

/* parse one complete value from the mirror file into *val. `maxv` bounds the
 * accepted range (gpio 1, adc UINT_MAX, pwm 1000). 0 = real value, -1 =
 * unreadable/unparsable — missing, empty, garbage, TRAILING garbage, or
 * out-of-range. One open/read/close, no retries: bounded (REQ-IO-008). */
static int pt_read_value(int ch, unsigned long maxv, unsigned long *val) {
	char path[128], buf[64];
	pt_path(path, sizeof(path), g_pt[ch].name);
	/* O_NONBLOCK: a fifo planted at the mirror path must not hang the io
	 * thread's bounded read; fstat rejects anything but a regular file. */
	int fd = open(path, O_RDONLY | O_NONBLOCK);
	if (fd < 0) return -1;
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) { close(fd); return -1; }
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	if (n == (ssize_t)(sizeof(buf) - 1)) {
		char c;
		if (read(fd, &c, 1) > 0) { close(fd); return -1; }
	}
	close(fd);
	if (n <= 0) return -1;
	buf[n] = '\0';
	if (strlen(buf) != (size_t)n) return -1; /* embedded NUL */
	char *end = NULL;
	errno = 0;
	unsigned long v = strtoul(buf, &end, 10);
	if (end == buf || errno != 0) return -1;
	if (buf[0] == '-') return -1; /* strtoul wraps a negative; reject it */
	while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r') end++;
	if (*end != '\0') return -1; /* trailing garbage */
	if (v > maxv) return -1;     /* out of the kind's range */
	*val = v;
	return 0;
}

int blob_io_gpio_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return 0;
	unsigned long v;
	if (pt_read_value(ch, 1, &v) < 0) return (int)g_pt[ch].last;
	g_pt[ch].last = (unsigned int)v;
	return (int)v;
}

int blob_io_gpio_read_checked(int ch, int *val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || !val) return -1;
	unsigned long v;
	if (pt_read_value(ch, 1, &v) < 0) return -1;
	g_pt[ch].last = (unsigned int)v;
	*val = (int)v;
	return 0;
}

int blob_io_adc_read_checked(int ch, unsigned int *val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || !val) return -1;
	unsigned long v;
	if (pt_read_value(ch, g_pt[ch].adc_max, &v) < 0) return -1; /* absent, garbage, or over-width */
	g_pt[ch].last = (unsigned int)v;
	*val = (unsigned int)v;
	return 0;
}

unsigned int blob_io_adc_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return 0;
	unsigned long v;
	/* any failure serves last-good (REQ-IO-003); the next poll heals it. */
	if (pt_read_value(ch, g_pt[ch].adc_max, &v) < 0) return g_pt[ch].last;
	g_pt[ch].last = (unsigned int)v;
	return (unsigned int)v;
}

static unsigned int g_write_faults;

void blob_io_gpio_write(int ch, int level) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return;
	if (pt_write_value(g_pt[ch].name, level ? 1u : 0u) != 0) {
		g_write_faults++;
		return;
	}
	g_pt[ch].last = level ? 1u : 0u;
}

void blob_io_pwm_write(int ch, unsigned int permille) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return;
	if (permille > 1000u) permille = 1000u; /* clamp above range (REQ-IO) */
	if (pt_write_value(g_pt[ch].name, permille) != 0) {
		g_write_faults++;
		return;
	}
	g_pt[ch].last = permille;
}

unsigned int blob_io_write_faults(void) {
	return g_write_faults;
}

void blob_io_close(void) {
	for (int i = 0; i < BLOB_IO_MAX; i++)
		g_pt[i].configured = 0;
}
