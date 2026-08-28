    .option norvc
    .section .text.init, "ax", @progbits
    .globl _start
    .type _start, @function
    .align 2
_start:
    csrwi   mie, 0
    csrci   mstatus, 8

    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __boot_stack_top

    la      t0, _bss_start
    la      t1, _bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    la      t0, trap_entry
    csrw    mtvec, t0
    call    rtthread_startup

    /* rtthread_startup must never return. */
    li      t0, 0x0000fff0
    li      t1, 0x600d00fe
    sw      t1, 0(t0)
3:
    j       3b
    .size _start, .-_start
