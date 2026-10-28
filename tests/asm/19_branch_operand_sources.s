# 19_branch_operand_sources -- where the branch comparison operands come from:
# ALU (EX/MEM, MEM/WB), compare instructions, multiplies, and loads (stall).
.text
    # slt -> bne (typical loop idiom): flag produced by the immediately preceding instruction
    li    $t0, 3
    li    $t1, 9
    slt   $t2, $t0, $t1
    bne   $t2, $zero, s1
    li    $s7, 1
s1: check $s7, 0, 1

    # sltu with negative-as-unsigned
    li    $t3, -1
    li    $t4, 1
    sltu  $t5, $t3, $t4         # 0xFFFFFFFF < 1 unsigned? no -> 0
    beq   $t5, $zero, s2
    li    $s7, 1
s2: check $s7, 0, 2

    # mul result feeding a branch directly
    li    $t6, 6
    li    $t7, 7
    mul   $t8, $t6, $t7
    li    $t9, 42
    beq   $t8, $t9, s3          # t8 from MEM/WB (one instruction between), t9 from EX/MEM
    li    $s7, 1
s3: check $s7, 0, 3

    # branch on a value computed by the previous instruction (EX/MEM -> branch)
    addiu $a0, $zero, 1
    bgtz  $a0, s4
    li    $s7, 1
s4: check $s7, 0, 4
    addiu $a1, $zero, -1
    bgtz  $a1, s5_bad           # not taken
    j     s5
s5_bad:
    li    $s7, 1
s5: check $s7, 0, 5

    # subtract-and-test-zero idiom
    li    $a2, 10
    li    $a3, 10
    subu  $v0, $a2, $a3
    beqz  $v0, s6
    li    $s7, 1
s6: check $s7, 0, 6

    # shift result used as branch operand
    li    $v1, 1
    sll   $s0, $v1, 31
    bltz  $s0, s7_ok
    li    $s7, 1
s7_ok:
    check $s7, 0, 7

    # both operands fresh from different producers, equal -> taken
    li    $s1, 5
    addiu $s2, $s1, 0
    beq   $s1, $s2, s8
    li    $s7, 1
s8: check $s7, 0, 8

    # branch whose operand comes from a load that itself followed a store (memory dependence)
    li    $s3, 17
    sw    $s3, 0($zero)
    lw    $s4, 0($zero)
    bne   $s3, $s4, __fail
    check $s7, 0, 9
.endtest
