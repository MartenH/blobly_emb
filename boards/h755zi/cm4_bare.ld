/* STM32H755 Cortex-M4 side: flash bank 2, D2 SRAM. The CM4 boots at 0x08100000
 * (factory option bytes: both cores auto-boot). SRAM4 (0x38000000, D3) is the
 * shared-memory window and deliberately NOT in this image's regions — shared cells
 * are absolute addresses owned by neither core's linker. */
MEMORY
{
    FLASH (rx) : ORIGIN = 0x08100000, LENGTH = 768K /* tail sectors 6+7 = the NvM journal pair (docs/nvm.md) */
    RAM  (rwx) : ORIGIN = 0x10000000, LENGTH = 256K  /* D2 SRAM1+2 (SRAM3 reserved for CM7 ADC DMA, emb#152) */
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

    /* remaining DTCM is heap/stack headroom */
    . = ALIGN(8);
    PROVIDE(end = .);   /* newlib _sbrk uses `end` if malloc is ever pulled in */
}
