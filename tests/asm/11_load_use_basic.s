# 11_load_use_basic -- a load followed immediately by a consumer needs a 1-cycle interlock.
# Covers the stall on rs only, rt only, rs+rt, and shift/immediate consumers, plus the
# *negative* cases where the register number matches but the field is a destination
# (lui, ori to the same rt, j) and therefore must NOT stall.
.text
    lw    $t0, w0($zero)        # 11
    addu  $t1, $t0, $zero       # rs-only dependence
    check $t1, 11, 1

    lw    $t2, w1($zero)        # 22
    addu  $t3, $zero, $t2       # rt-only dependence
    check $t3, 22, 2

    lw    $t4, w2($zero)        # 33
    addu  $t5, $t4, $t4         # rs and rt both depend
    check $t5, 66, 3

    lw    $t6, w3($zero)        # 44
    sll   $t7, $t6, 2           # shift-immediate reads rt only
    check $t7, 176, 4

    lw    $s0, w0($zero)        # 11
    addiu $s1, $s0, 100         # I-type consumer
    check $s1, 111, 5

    lw    $s2, w1($zero)        # 22
    sllv  $s3, $s2, $s2         # shift amount (rs) and value (rt) both from the load
    check $s3, 22 << 22, 6

    lw    $s4, w2($zero)        # 33
    slti  $s5, $s4, 40
    check $s5, 1, 7

    # no-stall cases: dest field coincides with load dest but is not read
    lw    $a0, w0($zero)
    lui   $a0, 0x1234           # rt is a destination
    check $a0, 0x12340000, 8
    lw    $a1, w1($zero)
    ori   $a1, $zero, 5         # rt is a destination, rs = $zero
    check $a1, 5, 9

    # consumer two instructions later: no stall, MEM/WB forwarding of load data
    lw    $a2, w3($zero)
    nop
    addiu $a3, $a2, 1
    check $a3, 45, 10

    # dependent chain through memory: load result feeds next load's data
    lw    $v0, w0($zero)
    addu  $v1, $v0, $v0         # stall
    addu  $v1, $v1, $v0         # v0 now older: MEM/WB forward
    check $v1, 33, 11

    # back-to-back loads, second independent
    lw    $t8, w0($zero)
    lw    $t9, w1($zero)
    addu  $t0, $t8, $t9         # t9 load-use stall, t8 from MEM/WB
    check $t0, 33, 12
.endtest
.data
w0: .word 11
w1: .word 22
w2: .word 33
w3: .word 44
