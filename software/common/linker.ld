OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
  . = ORIGIN(RAM);
  .text : ALIGN(8)
  {
    KEEP(*(.text.init))
    KEEP(*(.text.trap))
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(8)
  {
    *(.srodata .srodata.*)
    *(.rodata .rodata.*)
  } > RAM

  .data : ALIGN(8)
  {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } > RAM

  .bss (NOLOAD) : ALIGN(8)
  {
    _bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(8);
    _bss_end = .;
  } > RAM

  __global_pointer$ = ADDR(.data) + 0x800;
  _signature_addr = ORIGIN(RAM) + LENGTH(RAM) - 16;
  _stack_top = _signature_addr - 16;

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
  ASSERT(_bss_end < _stack_top - 8192, "firmware leaves less than 8 KiB of stack")
}
