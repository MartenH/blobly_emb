/* STM32 H7 target backend: register-level GPIO, no HAL (the can_fdcan.c style).
 *
 * The pin string ("PB0", "PC13") is parsed at cfg time into port/pin indexes;
 * blob_io_init() then brings each configured point up in the docs/io.md order —
 * for an OUTPUT the init level is written to BSRR BEFORE the pin is muxed from
 * its reset state (analog) to output mode, so there is no glitch window through
 * a floating pin into an active-high actuator (REQ-IO-009/013). Inputs are
 * plain MODER=input, no pull (the Nucleo button has its own RC network).
 *
 * Reads are one IDR load (REQ-IO-008, trivially wait-free) and cannot fail on
 * target — read_checked always has a real sample, and last-good bookkeeping
 * (the host mirror's torn-file rule, REQ-IO-003) has nothing to serve. Writes
 * are one BSRR store: atomic set/reset, no read-modify-write, so no faults to
 * count either. Same static 32-entry table shape as io_file.c; no heap. */
#include "io_port.h"
#include "board.h"    /* board_io_pin_reserved: the boards-layer pin-ownership table */
#include <stm32h7xx.h> /* CMSIS family dispatcher (build sets -DSTM32H735xx / -DSTM32H755xx); no HAL */

#define BLOB_IO_MAX 32

static struct {
	unsigned int port; /* 0..10 = GPIOA..GPIOK, parsed from the pin string at cfg */
	unsigned int pin;  /* 0..15 */
	int dir;           /* 0=in 1=out */
	unsigned int init;
	int configured;
} g_pt[BLOB_IO_MAX];

/* H7 GPIO blocks sit at a fixed 0x400 stride from GPIOA on AHB4; parts without
 * GPIOI (H72x/H73x) simply reserve that slot, so the arithmetic holds on both
 * benches. Same story for the AHB4ENR enable bits: GPIOAEN..GPIOKEN are bits
 * 0..10 in port-letter order. */
static GPIO_TypeDef *gpio(unsigned int port) {
	return (GPIO_TypeDef *)(GPIOA_BASE + (uint32_t)port * 0x0400UL);
}

/* "PA0".."PK15" -> port/pin indexes; anything else (no P, bad letter, no
 * digits, >15, trailing junk) is malformed and rejected at cfg. */
static int pin_parse(const char *s, unsigned int *port, unsigned int *pin) {
	if (!s || s[0] != 'P') return -1;
	if (s[1] < 'A' || s[1] > 'K') return -1;
	if (s[2] < '0' || s[2] > '9') return -1;
	unsigned int n = (unsigned int)(s[2] - '0');
	unsigned int i = 3;
	if (s[3] >= '0' && s[3] <= '9') {
		n = n * 10u + (unsigned int)(s[3] - '0');
		i = 4;
	}
	if (s[i] != '\0' || n > 15u) return -1;
	*port = (unsigned int)(s[1] - 'A');
	*pin = n;
	return 0;
}

/* Weak default: no platform-owned pads. Lives here (the only caller) so the
 * symbol always links; a board.c's strong table overrides it (board.h). */
__attribute__((weak)) int board_io_pin_reserved(int port, int pin) {
	(void)port;
	(void)pin;
	return 0;
}

/* board_io_pin_exists: the board's bonded-pad table (port 0=A..10=K). A pad can
 * be syntactically valid yet absent from this MCU/package — configuring it
 * "succeeds" into a floating nothing, so cfg rejects it up front (codex on
 * emb#150). Weak default says everything exists (legacy boards keep working);
 * each bench board declares its real map in board.c. */
__attribute__((weak)) int board_io_pin_exists(int port, int pin) {
	(void)port;
	(void)pin;
	return 1;
}

int blob_io_cfg(int ch, const char *name, const char *pin, int dir, unsigned int init_val) {
	(void)name; /* informational on target: the parsed pin IS the table key */
	if (ch < 0 || ch >= BLOB_IO_MAX || !name || !pin) return -1;
	if (pin_parse(pin, &g_pt[ch].port, &g_pt[ch].pin) < 0) return -1;
	/* the pad must be bonded on THIS package — an absent pad configures into a
	 * floating nothing and the init level never exists physically */
	if (!board_io_pin_exists((int)g_pt[ch].port, (int)g_pt[ch].pin)) return -1;
	/* docs/io.md "pins are exclusive" + REQ-IO-006: a pad the board assigned to
	 * CAN/SWD/ETH must never be re-muxed by an io point — reject before recording. */
	if (board_io_pin_reserved((int)g_pt[ch].port, (int)g_pt[ch].pin)) return -1;
	g_pt[ch].dir = dir ? 1 : 0;
	g_pt[ch].init = init_val ? 1u : 0u;
	g_pt[ch].configured = 1;
	return 0;
}

int blob_io_init(void) {
	for (int i = 0; i < BLOB_IO_MAX; i++) {
		if (!g_pt[i].configured) continue;
		GPIO_TypeDef *g = gpio(g_pt[i].port);
		unsigned int p = g_pt[i].pin;

		RCC->AHB4ENR |= (1u << g_pt[i].port); /* GPIOxEN, bits in port order */
		(void)RCC->AHB4ENR; /* read-back: let the clock settle before touching the port */

		if (g_pt[i].dir) {
			/* output: establish the init level in ODR via BSRR FIRST, while the
			 * pin still sits in its reset state — then mux to output, so the pad
			 * goes straight to the configured level (REQ-IO-009, docs/io.md). */
			g->BSRR = g_pt[i].init ? (1u << p) : (1u << (p + 16u));
			g->MODER = (g->MODER & ~(3u << (p * 2u))) | (1u << (p * 2u)); /* 01 = output */
			g->OSPEEDR &= ~(3u << (p * 2u)); /* 00 = low speed: LED/logic cadence, no fast edges */
			g->PUPDR &= ~(3u << (p * 2u));   /* no pull on a driven pad */
		} else {
			g->MODER &= ~(3u << (p * 2u)); /* 00 = input */
			g->PUPDR &= ~(3u << (p * 2u)); /* no pull: the board's button has external RC */
		}
	}
	return 0;
}

int blob_io_gpio_read(int ch) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return 0;
	return (gpio(g_pt[ch].port)->IDR >> g_pt[ch].pin) & 1u ? 1 : 0;
}

int blob_io_gpio_read_checked(int ch, int *val) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured || !val) return -1;
	/* a real pad always samples: same IDR load, never a fabricated value */
	*val = blob_io_gpio_read(ch);
	return 0;
}

void blob_io_gpio_write(int ch, int level) {
	if (ch < 0 || ch >= BLOB_IO_MAX || !g_pt[ch].configured) return;
	unsigned int p = g_pt[ch].pin;
	gpio(g_pt[ch].port)->BSRR = level ? (1u << p) : (1u << (p + 16u)); /* atomic, no RMW */
}

unsigned int blob_io_write_faults(void) {
	return 0; /* a BSRR store cannot fail; only the host mirror has write faults */
}

void blob_io_close(void) {
	/* forget the table only — pins keep their configured mode and level: yanking
	 * an actuator back to analog on close would be a glitch, not a cleanup. */
	for (int i = 0; i < BLOB_IO_MAX; i++)
		g_pt[i].configured = 0;
}
