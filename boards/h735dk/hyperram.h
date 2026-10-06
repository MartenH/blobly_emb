/* STM32H735G-DK 16 MB HyperRAM (S70KL1281) on OCTOSPI2, memory-mapped at HYPERRAM_BASE. */
#ifndef BOARD_HYPERRAM_H
#define BOARD_HYPERRAM_H
#include <stdint.h>

#define HYPERRAM_BASE 0x70000000u
#define HYPERRAM_SIZE 0x01000000u

/* hyperram_init: OCTOSPI2 in HyperBus memory-mapped mode. Returns 0 when a write/read-back
 * pattern over the first and last 64 KiB passes, -1 otherwise (the memory is then unusable). */
int hyperram_init(void);

#endif
