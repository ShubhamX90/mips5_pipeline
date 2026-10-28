# 08_fwd_priority -- several in-flight writers of the same register.
# The youngest writer must win: EX/MEM has priority over MEM/WB, which has
# priority over the register file.
.text
    li    $t0, 1
    li    $t0, 2
    li    $t0, 3
    addu  $t1, $t0, $zero       # EX/MEM=3 (youngest), MEM/WB=2, WB-bypass=1
    check $t1, 3, 1

    li    $t2, 10
    li    $t2, 20
    addu  $t3, $t2, $t2         # EX/MEM = 20 beats MEM/WB = 10
    check $t3, 40, 2

    # read-modify-write counter: every instruction depends on the previous one
    li    $t4, 0
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    addiu $t4, $t4, 1
    check $t4, 8, 3

    # xor-swap: three mutually dependent writes to two registers
    li    $s0, 0x1234
    li    $s1, 0xABCD
    xor   $s0, $s0, $s1
    xor   $s1, $s0, $s1
    xor   $s0, $s0, $s1
    check $s0, 0xABCD, 4
    check $s1, 0x1234, 5

    # overwrite with a value that depends on the older value
    li    $a0, 5
    addu  $a0, $a0, $a0         # 10
    addu  $a0, $a0, $a0         # 20
    subu  $a0, $zero, $a0       # -20
    check $a0, -20, 6

    # older writer is a slow-looking op (mul), younger is addiu to same reg
    li    $a1, 7
    mul   $a2, $a1, $a1
    addiu $a2, $a2, 1
    mul   $a2, $a2, $a1         # (49+1)*7
    check $a2, 350, 7
.endtest
