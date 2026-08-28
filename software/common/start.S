    .option norvc
    .section .text.init, "ax", @progbits
    .globl _start
    .type _start, @function
    .align 2
_start:
    la      sp, _stack_top
    la      gp, __global_pointer$

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
    call    main

    li      t0, 0x0000fff0
    li      t1, 0x600d0000
    or      t1, t1, a0
    sw      t1, 0(t0)
3:
    j       3b
    .size _start, .-_start

    .section .text.trap, "ax", @progbits
    .globl trap_entry
    .type trap_entry, @function
    .align 2
trap_entry:
    csrr    t0, mcause
    li      t1, 0x0000fff0
    li      t2, 0xdead0000
    or      t2, t2, t0
    sw      t2, 0(t1)
4:
    j       4b
    .size trap_entry, .-trap_entry
