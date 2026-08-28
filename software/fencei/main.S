    .option norvc
    .section .text, "ax", @progbits
    .globl main
    .type main, @function
    .align 2
main:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    call    patch_target
    addi    t0, zero, 1
    bne     a0, t0, fail

    la      t0, patch_target
    lui     t1, 0x02a00
    addi    t1, t1, 0x513
    sw      t1, 0(t0)
    fence.i

    call    patch_target
    addi    t0, zero, 42
    bne     a0, t0, fail
    addi    a0, zero, 0
    lw      ra, 12(sp)
    addi    sp, sp, 16
    jalr    zero, 0(ra)
fail:
    addi    a0, zero, 5
    lw      ra, 12(sp)
    addi    sp, sp, 16
    jalr    zero, 0(ra)
    .size main, .-main

    .align 5
patch_target:
    addi    a0, zero, 1
    jalr    zero, 0(ra)
