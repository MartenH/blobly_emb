/* STM32H755 (CM7, flash bank 1)IG ThreadX image (P3c-1 Phase 3). Same section layout as the QEMU
 * foundation (threadx_min/threadx.ld) — the ThreadX bring-up triad (crt0/vectors/
 * tx_initialize_low_level) depends on these symbols (__stack_end__, __data_*,
 * __bss_*, __RAM_segment_used_end__) — retargeted to real H735 memory:
 *   FLASH 1 MB @ 0x08000000   (code + .vectors first, so reset reads it)
 *   DTCM  128 KB @ 0x20000000 (ThreadX static memory: stacks, ring, .data/.bss)
 * The FDCAN message RAM (SRAMCAN) is a fixed peripheral address the driver writes
 * directly and is NOT placed here (Phase 3 dumps over semihosting, no CAN yet). */
/* The bootloader chain links the SAME image at APP_VECTORS (bootmap.h:
 * 0x08020000 header + 0x400 vector alignment): pass
 *   -Wl,--defsym,__flash_base__=0x08020400,--defsym,__flash_len__=0xDFC00
 * (make APP_LINK=boot). Default = standalone at the bank-1 base. */
MEMORY
{
  RAM   (wx) : ORIGIN = 0x20000000, LENGTH = 0x00020000   /* 128 KiB DTCM */
  FLASH (rx) : ORIGIN = DEFINED(__flash_base__) ? __flash_base__ : 0x08000000,
               LENGTH = DEFINED(__flash_len__)  ? __flash_len__  : 0x00100000
  D2SRAM (wx) : ORIGIN = 0x30040000, LENGTH = 0x00008000   /* D2 SRAM3: DMA-reachable, clear of the CM4 AMP SRAM1 (codex emb#152) */
}

__STACKSIZE__ = 1024;
__STACKSIZE_PROCESS__ = 0;
__HEAPSIZE__ = 0;   /* no runtime heap (AGENTS.md hard invariant) — ThreadX uses static memory */

SECTIONS
{
  .vectors :
  {
    KEEP(*(.vectors .vectors.*))
  } > FLASH

	.text :
	{
		*(.text*)

		KEEP(*(.init))
		KEEP(*(.fini))

		/* .ctors */
		*crtbegin.o(.ctors)
		*crtbegin?.o(.ctors)
		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .ctors)
    __ctors_start__ = ALIGN(4);
		*(SORT(.ctors.*))
		*(.ctors)
    __ctors_end__ = ALIGN(4);

		/* .dtors */
 		*crtbegin.o(.dtors)
 		*crtbegin?.o(.dtors)
 		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .dtors)
    __dtors_start__ = ALIGN(4);
 		*(SORT(.dtors.*))
 		*(.dtors)
    __dtors_end__ = ALIGN(4);

		*(.rodata*)

		KEEP(*(.eh_frame*))
	} > FLASH

	.ARM.extab :
	{
		*(.ARM.extab* .gnu.linkonce.armextab.*)
	} > FLASH

	__exidx_start = .;
	.ARM.exidx :
	{
		*(.ARM.exidx* .gnu.linkonce.armexidx.*)
	} > FLASH
	__exidx_end = .;

	__data_load_start__ = ALIGN (4);

	.data : AT (__data_load_start__)
	{
		__data_start__ = .;

		*(vtable)
		*(.data*)

		. = ALIGN(4);
		/* preinit data */
		PROVIDE_HIDDEN (__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN (__preinit_array_end = .);

		. = ALIGN(4);
		/* init data */
		PROVIDE_HIDDEN (__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN (__init_array_end = .);

		. = ALIGN(4);
		/* finit data */
		PROVIDE_HIDDEN (__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN (__fini_array_end = .);

		KEEP(*(.jcr*))
		. = ALIGN(4);
		/* All data end */

    __data_end__ = .;

	} > RAM

	.bss :
	{
		. = ALIGN(4);
		__bss_start__ = .;
		*(.bss*)
		*(COMMON)
		. = ALIGN(4);
		__bss_end__ = .;

	} > RAM

	.heap (COPY):
	{
    __heap_start__ = ALIGN(4);
    *(.heap)
    . = ALIGN(. + __HEAPSIZE__, 4);
    __heap_end__ = ALIGN(4);
	} > RAM

  /* 8-byte aligned so the initial MSP (= __stack_end__, loaded by _start) meets the
     AAPCS 8-byte stack alignment the hard-float ABI requires. */
  .stack ALIGN(8) (NOLOAD) :
  {
    __stack_start__ = ALIGN(8);
    *(.stack)
    . = ALIGN(. + __STACKSIZE__, 8);
    __stack_end__ = ALIGN(8);
  } > RAM

  __RAM_segment_used_end__ = .; /* ThreadX first_unused_memory — captured while . is in RAM/DTCM */

.dma_buf (NOLOAD) :
  {
    *(.dma_buf .dma_buf.*)   /* ADC/DMA latest-value buffers: DMA cannot reach DTCM */
  } > D2SRAM
}
