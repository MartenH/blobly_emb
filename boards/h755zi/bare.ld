/* STM32H755 (CM7, flash bank 1)IG: 1 MB flash @ 0x08000000, 128 KB DTCM @ 0x20000000.
 * Same minimal script as h735_blinky. The FDCAN message RAM (SRAMCAN) is a fixed
 * peripheral address the driver writes directly, so it is NOT placed here — this
 * script only covers our code (flash) and .data/.bss/stack (DTCM). */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 1024K
    RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
    D2SRAM (wx) : ORIGIN = 0x30040000, LENGTH = 0x00008000   /* D2 SRAM3: DMA-reachable, clear of the CM4 AMP image's SRAM1 (codex emb#152) */
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
    } > RAM AT> FLASH

    .bss : {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    .dma_buf (NOLOAD) : {
        *(.dma_buf .dma_buf.*)   /* ADC/DMA latest-value buffers: DMA cannot reach DTCM */
    } > D2SRAM

    /* remaining DTCM is heap/stack headroom */
    . = ALIGN(8);
    PROVIDE(end = .);   /* newlib _sbrk uses `end` if malloc is ever pulled in */
}
