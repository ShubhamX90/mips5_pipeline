# 07_regfile_bypass -- distance-3 and distance-4 RAW hazards.
# At distance 3 the producer is in WB while the consumer is in ID: no forwarding
# network is involved, the register file's write-through bypass supplies the value.
# At distance 4 the value is simply read from the array.
.text
    li    $t0, 21
    nop
    nop
    addu  $t1, $t0, $t0         # distance 3: write-through on both ports
    check $t1, 42, 1

    li    $t2, 5
    li    $t3, 6
    nop
    addu  $t4, $t2, $t3         # t2 distance 3 (rs), t3 distance 2 (rt)
    check $t4, 11, 2

    li    $t5, 100
    nop
    nop
    nop
    addu  $t6, $t5, $t5         # distance 4
    check $t6, 200, 3

    # write-through must not leak the wrong register
    li    $s0, 1
    li    $s1, 2
    li    $s2, 3
    li    $s3, 4
    addu  $s4, $s0, $s1         # s0 d4, s1 d3
    addu  $s5, $s2, $s3         # s2 d4, s3 d3 (after s4: fwd none)
    check $s4, 3, 4
    check $s5, 7, 5

    # three back-to-back producers then consumer reading all three over time
    li    $a0, 10
    li    $a1, 20
    li    $a2, 30
    addu  $v0, $a0, $a1         # a0 d3 (bypass), a1 d2 (MEM/WB)
    addu  $v1, $v0, $a2         # v0 d1, a2 d4... a2 is d3 here (bypass)
    check $v0, 30, 6
    check $v1, 60, 7
.endtest
