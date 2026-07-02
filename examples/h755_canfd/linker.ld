/* STM32H755ZI (Cortex-M7 core): 2 MB flash @ 0x08000000, 128 KB DTCM @ 0x20000000.
 * Minimal hand-written script — the M4 core, the other SRAM banks, and the FDCAN
 * message RAM (a fixed peripheral address the driver writes directly) are not
 * placed here; this covers the M7's code (flash) and .data/.bss/stack (DTCM). */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 2048K
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

    . = ALIGN(8);
    PROVIDE(end = .);
}
