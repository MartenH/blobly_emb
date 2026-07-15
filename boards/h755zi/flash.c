/* boards/h755zi/flash.c — the embedded flash driver (erase/program) for the
 * bootloader's FlashOps seam (docs/bootloader.md).
 *
 * *** DRY-CODED, BENCH-UNVERIFIED *** — written from RM0399 register offsets
 * with no silicon run yet. Every constant below is on the P1 bench checklist:
 * key values, CR/SR bit positions, QW-wait semantics, ECC/UNDERRUN error bits.
 *
 * STM32H755 geometry: 2 banks x 8 sectors x 128 KB; program word = 256 bits
 * (32 bytes, 8 consecutive u32 writes, naturally triggered when the word
 * buffer fills). Bank 1 @ 0x08000000, bank 2 @ 0x08100000. */
#include <stdint.h>

#define FLASHR_BASE 0x52002000u
#define FLASH_KEY1 0x45670123u
#define FLASH_KEY2 0xCDEF89ABu

#define BANK1_ADDR 0x08000000u
#define BANK2_ADDR 0x08100000u
#define BANK_SIZE 0x00100000u
#define SECTOR_SIZE 0x00020000u /* 128 KB */

/* per-bank register block: bank1 at +0x00, bank2 at +0x100 */
#define REG(bank, off) (*(volatile uint32_t *)(FLASHR_BASE + (bank) * 0x100u + (off)))
#define KEYR(b) REG(b, 0x004u)
#define CR(b) REG(b, 0x00Cu)
#define SR(b) REG(b, 0x010u)
#define CCR(b) REG(b, 0x014u)

/* CR bits */
#define CR_LOCK (1u << 0)
#define CR_PG (1u << 1)
#define CR_SER (1u << 2)
#define CR_PSIZE_32 (2u << 4)
#define CR_START (1u << 7)
#define CR_SNB_SHIFT 8u
/* SR bits */
#define SR_BSY (1u << 0)
#define SR_QW (1u << 2)
/* error summary: WRPERR|PGSERR|STRBERR|INCERR|OPERR|RDPERR|RDSERR|SNECCERR|DBECCERR */
/* error summary EXCLUDING SNECCERR (bit 25): a corrected single-bit event is
 * data-valid and must not fail a program/erase verdict (it is cleared, not
 * counted). DBECCERR stays in. */
#define SR_ERRS 0x0DEE0000u

static int bank_of(uint32_t addr) {
	if (addr >= BANK1_ADDR && addr < BANK1_ADDR + BANK_SIZE) return 0;
	if (addr >= BANK2_ADDR && addr < BANK2_ADDR + BANK_SIZE) return 1;
	return -1;
}

static void unlock(int b) {
	if (CR(b) & CR_LOCK) {
		KEYR(b) = FLASH_KEY1;
		KEYR(b) = FLASH_KEY2;
	}
}

static int wait_done(int b) {
	while (SR(b) & (SR_BSY | SR_QW)) {
	}
	uint32_t errs = SR(b) & SR_ERRS;
	if (errs) {
		CCR(b) = errs; /* clear for the next attempt */
		return 0;
	}
	return 1;
}

/* bflash_erase: erase every 128 KB sector overlapping [addr, addr+size). */
int bflash_erase(uint32_t addr, uint32_t size) {
	uint32_t end = addr + size;
	while (addr < end) {
		int b = bank_of(addr);
		if (b < 0) return 0;
		uint32_t base = b ? BANK2_ADDR : BANK1_ADDR;
		uint32_t snb = (addr - base) / SECTOR_SIZE;
		unlock(b);
		CR(b) = CR_SER | CR_PSIZE_32 | (snb << CR_SNB_SHIFT);
		CR(b) |= CR_START;
		if (!wait_done(b)) return 0;
		CR(b) = 0;
		addr = base + (snb + 1u) * SECTOR_SIZE;
	}
	return 1;
}

/* bflash_program: len is a multiple of 32 (the boot layer stages to prog_word);
 * addr is 32-byte aligned inside an erased region. */
int bflash_program(uint32_t addr, const uint8_t *data, uint32_t len) {
	if ((addr & 31u) || (len & 31u)) return 0;
	for (uint32_t off = 0; off < len; off += 32u) {
		int b = bank_of(addr + off);
		if (b < 0) return 0;
		unlock(b);
		CR(b) = CR_PG | CR_PSIZE_32;
		volatile uint32_t *dst = (volatile uint32_t *)(addr + off);
		const uint8_t *src = data + off;
		for (int i = 0; i < 8; i++) {
			uint32_t w = (uint32_t)src[4 * i] | ((uint32_t)src[4 * i + 1] << 8) |
			             ((uint32_t)src[4 * i + 2] << 16) | ((uint32_t)src[4 * i + 3] << 24);
			dst[i] = w;
		}
		__asm__ volatile("dsb");
		if (!wait_done(b)) {
			CR(b) = 0;
			return 0;
		}
		CR(b) = 0;
	}
	return 1;
}

/* SR double-ECC flags (per bank): DBECCERR reports a torn/rotted flash word
 * detected during a read — RM0399: the data returned is corrupted and the
 * FLASH raises a flag (an interrupt only if DBECCERRIE is enabled, which we
 * never enable), so a flag-checked copy is the fault-tolerant read. BENCH
 * ITEM: verify no BusFault escalation path is configured on this part. */
#define SR_SNECCERR (1u << 25) /* single-bit: CORRECTED data, flag still sets */
#define SR_DBECCERR (1u << 26) /* double-bit: data invalid */

/* clear BOTH ECC flags: a lingering SNECCERR from a read would otherwise be
 * read by the next program's wait_done (SR_ERRS includes it) as a failure. */
static void ecc_clear(int b) { CCR(b) = SR_SNECCERR | SR_DBECCERR; }
/* only DOUBLE-bit errors invalidate data — single-bit was corrected. */
static int ecc_fired(int b) { return (SR(b) & SR_DBECCERR) != 0; }

/* bflash_read: flash is memory-mapped — a flag-checked, word-wise copy. A
 * word whose read raises a double-ECC error is returned ZEROED (an all-zero
 * record can never parse valid: the CRC layer above rejects it) and the flag
 * is cleared so the scan continues. The hook also keeps the session logic
 * testable off-target. */
int bflash_read(uint32_t addr, uint8_t *out, uint32_t len) {
	uint32_t i = 0;
	while (i < len) {
		int b = bank_of(addr + i);
		if (b < 0) {
			/* not our flash (RAM-backed tests, headers): plain copy */
			out[i] = *(const uint8_t *)(addr + i);
			i++;
			continue;
		}
		uint32_t chunk = 32u - ((addr + i) & 31u); /* to the flash-word edge */
		if (chunk > len - i) chunk = len - i;
		ecc_clear(b);
		const uint8_t *src = (const uint8_t *)(addr + i);
		for (uint32_t k = 0; k < chunk; k++) out[i + k] = src[k];
		if (ecc_fired(b)) {
			for (uint32_t k = 0; k < chunk; k++) out[i + k] = 0; /* CRC-rejected */
		}
		ecc_clear(b); /* ALWAYS: a corrected-only SNECCERR must not linger either */
		i += chunk;
	}
	return 1;
}

/* bflash_blank: "is this range erased?" — the journal's blank hook. A word
 * whose read fires double-ECC was TOUCHED (a torn program can read all-0xFF
 * on weak cells while being unprogrammable): not blank. Otherwise the erased
 * pattern decides. */
int bflash_blank(uint32_t addr, uint32_t len) {
	for (uint32_t i = 0; i < len; i += 32u) {
		int b = bank_of(addr + i);
		if (b < 0) return 0;
		ecc_clear(b);
		const uint32_t *w = (const uint32_t *)(addr + i);
		uint32_t acc = 0xFFFFFFFFu;
		for (int k = 0; k < 8; k++) acc &= w[k];
		int fired = ecc_fired(b);
		ecc_clear(b); /* ALWAYS: corrected-only events must not linger */
		if (fired) return 0; /* touched word: never the frontier */
		if (acc != 0xFFFFFFFFu) return 0;
	}
	return 1;
}
