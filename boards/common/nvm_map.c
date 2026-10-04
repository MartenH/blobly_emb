/* boards/common/nvm_map.c — where the NvM journal lives (docs/nvm.md): the two flash sectors the
 * board's bootmap.h names (NVM_A_ADDR, NVM_B_ADDR, NVM_SIZE — the flash layout's one statement,
 * beside the boot and application regions, which they must lie outside of). Linked by every image
 * the generator gives a journal (loom2v glue_build_lines: the nvm_map_* declarations), with the
 * board's flash driver (board.mk BOARD_FLASH, the bootloader's driver too). */
#include <stdint.h>
#include "bootmap.h"

#if !defined(NVM_A_ADDR) || !defined(NVM_B_ADDR) || !defined(NVM_SIZE)
#error "this board's bootmap.h names no NvM journal sectors (NVM_A_ADDR, NVM_B_ADDR, NVM_SIZE)"
#endif

uint32_t nvm_map_a(void) { return NVM_A_ADDR; }
uint32_t nvm_map_b(void) { return NVM_B_ADDR; }
uint32_t nvm_map_size(void) { return NVM_SIZE; }
