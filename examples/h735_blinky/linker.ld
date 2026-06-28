/* STM32H735IG: 1 MB flash @ 0x08000000, 128 KB DTCM @ 0x20000000.
 * Minimal hand-written script — flash holds code + .data init image; DTCM holds
 * .data/.bss/stack. (Plenty of other SRAM exists; DTCM is enough for a blinky.) */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 1024K
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
