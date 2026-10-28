# 05_raw_forward_exmem -- distance-1 RAW hazards (producer in MEM, consumer in EX).
# Exercises the EX/MEM -> EX forwarding path on rs, on rt, and on both operands,
# with chains long enough that every instruction depends on its predecessor.
.text
    # doubling chain: each addu consumes both operands from EX/MEM
    addiu $t0, $zero, 1
    addu  $t1, $t0, $t0
    addu  $t2, $t1, $t1
    addu  $t3, $t2, $t2
    addu  $t4, $t3, $t3
    check $t1, 2, 1
    check $t2, 4, 2
    check $t3, 8, 3
    check $t4, 16, 4

    # rs forwarded from EX/MEM (immediate op)
    addiu $s0, $zero, 100
    addiu $s1, $s0, 5
    addiu $s2, $s1, -5
    addiu $s3, $s2, -1
    check $s1, 105, 5
    check $s2, 100, 6
    check $s3, 99, 7

    # rt forwarded from EX/MEM while rs is old (comes from the register file)
    addiu $s4, $zero, 7
    nop
    nop
    nop
    nop
    addiu $s5, $zero, 40
    subu  $s6, $s4, $s5         # 7 - 40
    check $s6, -33, 8

    # non-commutative op, operand order must survive forwarding
    addiu $t5, $zero, 50
    addiu $t6, $zero, 8
    subu  $t7, $t5, $t6         # rt=t6 from EX/MEM, rs=t5 from MEM/WB
    subu  $t8, $t6, $t7         # rs=t6 (old), rt=t7 from EX/MEM
    check $t7, 42, 9
    check $t8, -34, 10

    # logical/compare ops fed straight from EX/MEM
    li    $a0, 0xF0F0
    andi  $a1, $a0, 0x0FF0
    ori   $a2, $a1, 0x000F
    xori  $a3, $a2, 0x00FF
    slt   $v0, $a3, $a2
    check $a1, 0x00F0, 11
    check $a2, 0x00FF, 12
    check $a3, 0x0000, 13
    check $v0, 1, 14
.endtest
