# 09_fwd_both_operands -- rs and rt forwarded from *different* stages in the same cycle.
.text
    li    $s0, 3
    li    $s1, 5
    li    $s2, 4
    li    $s3, 6
    nop
    nop
    nop
    addu  $t0, $s0, $s1         # t0 = 8
    addu  $t1, $s3, $s2         # t1 = 10
    mul   $t2, $t0, $t1         # rs <- MEM/WB (t0), rt <- EX/MEM (t1)  => 80
    addu  $t3, $t2, $t2         # both <- EX/MEM                          => 160
    addiu $t5, $t3, 3           # 163
    sllv  $t6, $t5, $t5         # shift amount & value from the same fwd  => 163 << 3
    check $t0, 8, 1
    check $t1, 10, 2
    check $t2, 80, 3
    check $t3, 160, 4
    check $t6, 1304, 5

    # rs <- EX/MEM, rt <- MEM/WB
    nop
    nop
    nop
    addu  $a0, $s0, $zero       # 3
    addu  $a1, $s1, $zero       # 5
    subu  $a2, $a1, $a0         # rs = a1 (EX/MEM), rt = a0 (MEM/WB) => 2
    subu  $a3, $a0, $a1         # rs = a0 (MEM/WB), rt = a1 (WB bypass d2)... => -2
    check $a2, 2, 6
    check $a3, -2, 7

    # branch comparing two registers forwarded from different stages
    li    $v0, 77
    li    $v1, 77
    beq   $v0, $v1, ok1
    li    $s7, 1                # wrong path
ok1:
    check $s7, 0, 8

    # store: base from MEM/WB, data from EX/MEM
    li    $t7, 200
    li    $t8, 0x5A5A
    sw    $t8, 0($t7)
    lw    $t9, 200($zero)
    check $t9, 0x5A5A, 9
.endtest
