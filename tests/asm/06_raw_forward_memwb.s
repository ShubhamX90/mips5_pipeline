# 06_raw_forward_memwb -- distance-2 RAW hazards (producer in WB, consumer in EX).
# One independent instruction separates producer and consumer, so the value must
# come from the MEM/WB -> EX forwarding path.
.text
    addiu $t0, $zero, 10
    addiu $t9, $zero, 1         # independent filler
    addu  $t1, $t0, $t9         # rs <- MEM/WB (t0), rt <- EX/MEM (t9)
    check $t1, 11, 1

    addiu $s0, $zero, 6
    addiu $s1, $zero, 9
    addiu $t9, $zero, 0         # filler
    addu  $s2, $s0, $s1         # rs <- MEM/WB? (s0 is distance 3 here -> bypass), rt dist 2
    check $s2, 15, 2

    # both operands the same register at distance 2
    addiu $s3, $zero, 21
    addiu $t9, $zero, 0
    addu  $s4, $s3, $s3
    check $s4, 42, 3

    # rs-only and rt-only at distance 2
    addiu $a0, $zero, 1000
    addiu $a1, $zero, 1
    addiu $a2, $zero, 3
    subu  $a3, $a0, $a2         # a0 dist 3 (bypass), a2 dist 1
    subu  $v0, $a2, $a1         # a2 dist 2 (MEM/WB) rs, a1 dist 3
    check $a3, 997, 4
    check $v0, 2, 5

    # chain with a gap of one between each dependent pair
    addiu $t2, $zero, 2
    addiu $t3, $zero, 0
    addu  $t4, $t2, $t2         # 4
    addiu $t3, $t3, 1
    addu  $t5, $t4, $t4         # 8   (t4 two back)
    addiu $t3, $t3, 1
    addu  $t6, $t5, $t5         # 16
    addiu $t3, $t3, 1
    check $t6, 16, 6
    check $t3, 3, 7
.endtest
