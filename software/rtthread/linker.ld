OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
  . = ORIGIN(RAM);
  .text : ALIGN(16)
  {
    KEEP(*(.text.init))
    KEEP(*(.text.entry))
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(16)
  {
    *(.srodata .srodata.*)
    *(.rodata .rodata.*)
  } > RAM

  .rti_fn : ALIGN(4)
  {
    KEEP(*(SORT(.rti_fn*)))
  } > RAM

  .finsh_symtab : ALIGN(4)
  {
    __fsymtab_start = .;
    KEEP(*(FSymTab))
    __fsymtab_end = .;
    __vsymtab_start = .;
    KEEP(*(VSymTab))
    __vsymtab_end = .;
  } > RAM

  .data : ALIGN(16)
  {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } > RAM

  .bss (NOLOAD) : ALIGN(16)
  {
    _bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    _bss_end = .;
  } > RAM

  __global_pointer$ = ADDR(.data) + 0x800;

  /* Top-of-RAM ownership: signature, IRQ stack, guard, boot stack, guard. */
  _signature_addr = ORIGIN(RAM) + LENGTH(RAM) - 16;
  __irq_stack_top = _signature_addr - 16;
  __irq_stack_bottom = __irq_stack_top - 2048;
  __irq_guard_bottom = __irq_stack_bottom - 64;
  __boot_stack_top = __irq_guard_bottom;
  __boot_stack_bottom = __boot_stack_top - 2048;
  __boot_guard_bottom = __boot_stack_bottom - 64;
  __heap_end = __boot_guard_bottom;
  _sp = __irq_stack_top;

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }

  ASSERT((_sp & 15) == 0, "IRQ stack is not 16-byte aligned")
  ASSERT((__boot_stack_top & 15) == 0, "boot stack is not 16-byte aligned")
  ASSERT(_bss_end < __heap_end, "RT-Thread image overlaps reserved stacks")
}
