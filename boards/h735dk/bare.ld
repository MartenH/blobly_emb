/* STM32H735IG: 1 MB flash @ 0x08000000, 128 KB DTCM @ 0x20000000.
 * Same minimal script as h735_blinky. The FDCAN message RAM (SRAMCAN) is a fixed
 * peripheral address the driver writes directly, so it is NOT placed here — this
 * script only covers our code (flash) and .data/.bss/stack (DTCM). */
ENTRY(Reset_Handler)

/* The bootloader passes -Wl,--defsym,__flash_len__=0x20000 (BOOT_SIZE, sector 0)
 * so the linker ENFORCES the boot/app boundary: an image that outgrows sector 0
 * fails to link instead of overflowing into APP_BASE when flashed (codex emb#140).
 * Standalone bare apps omit it and get the full 1 MB. */
MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000,
  D2SRAM (wx) : ORIGIN = 0x30000000, LENGTH = 0x00008000   /* 32 KiB D2 AHB SRAM: DMA-reachable (ADC) */
                 LENGTH = DEFINED(__flash_len__) ? __flash_len__ : 1024K
    RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    .isr_vector : { KEEP(*(.isr_vector)) } > FLASH

    .text : {
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    /* libgcc/newlib unwinding tables — keep the linker happy, never used. */
    .ARM.exidx : { *(.ARM.exidx*) } > FLASH

    _sidata = LOADADDR(.data);
    .data : {
        . = ALIGN(4);
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    .dma_buf (NOLOAD) :
  {
    *(.dma_buf .dma_buf.*)   /* ADC/DMA latest-value buffers: DMA cannot reach DTCM */
  } > D2SRAM

  } > RAM AT> FLASH

    .bss : {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    /* remaining DTCM is heap/stack headroom */
    . = ALIGN(8);
    PROVIDE(end = .);   /* newlib _sbrk uses `end` if malloc is ever pulled in */
}
