# 22_indirect_jumps -- jump table dispatch (lw -> jr load-use), jalr with default and
# explicit link registers, jalr whose target register is also the link register.
.text
    li    $s0, 0                # accumulated result
    li    $t0, 0                # case index 0..3
disp:
    sll   $t1, $t0, 2
    lw    $t2, table($t1)
    jr    $t2                   # load-use into jr
case0:
    addiu $s0, $s0, 1
    j     next
case1:
    addiu $s0, $s0, 10
    j     next
case2:
    addiu $s0, $s0, 100
    j     next
case3:
    addiu $s0, $s0, 1000
next:
    addiu $t0, $t0, 1
    slti  $t3, $t0, 4
    bne   $t3, $zero, disp
    check $s0, 1111, 1

    # jalr with default $ra
    la    $t4, sub1
    jalr  $t4
    check $v0, 77, 2

    # jalr with an explicit link register
    la    $t5, sub2
    la    $t6, after2
    jalr  $s5, $t5
after2:
    checkr $s5, $t6, 3
    check $v1, 88, 4

    # jalr where link register == target register (target read before link written)
    la    $t7, sub3
    jalr  $t7, $t7
    check $v0, 99, 5

    # jump target loaded long before the jr (no stall needed)
    lw    $t8, ftab($zero)
    nop
    nop
    nop
    jr    $t8
    li    $s7, 1                # wrong path
fin:
    check $s7, 0, 6
.endtest
sub1:
    li    $v0, 77
    jr    $ra
sub2:
    li    $v1, 88
    jr    $s5
sub3:
    li    $v0, 99
    jr    $t7
.data
table: .word case0, case1, case2, case3
ftab:  .word fin
