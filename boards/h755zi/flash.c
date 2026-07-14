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
#define SR_ERRS 0x0FEE0000u

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

/* bflash_read: flash is memory-mapped — a plain copy (the hook exists so the
 * session logic stays testable off-target).
 *
 * BENCH TODO (ECC): a power-cut-torn flash word can raise an ECC double-error
 * (bus fault / ECCD) ON READ on the H7 — the NvM journal's mount scan will hit
 * exactly that after a real power cut. This read must become fault-tolerant
 * (handle/clear ECCD, return the garbage bytes; the CRC layer above rejects
 * them) before the journal runs on silicon. */
int bflash_read(uint32_t addr, uint8_t *out, uint32_t len) {
	const uint8_t *src = (const uint8_t *)addr;
	for (uint32_t i = 0; i < len; i++) out[i] = src[i];
	return 1;
}
