# 15_load_gap -- load data consumed 1 and 2 instructions after the load.
# Gap 1: MEM/WB -> EX forwarding of *load* data.  Gap 2: register-file write-through.
.text
    lw    $t0, v0($zero)        # 100
    addiu $t9, $zero, 1         # gap 1
    addu  $t1, $t0, $t9         # forwarded from MEM/WB
    check $t1, 101, 1

    lw    $t2, v1($zero)        # 200
    addiu $t9, $zero, 1
    addiu $t9, $zero, 2         # gap 2
    addu  $t3, $t2, $t9         # write-through in the register file
    check $t3, 202, 2

    lw    $t4, v0($zero)
    lw    $t5, v1($zero)
    addu  $t6, $t4, $t5         # t4 gap 1 (MEM/WB), t5 gap 0 (stall)
    check $t6, 300, 3

    lw    $s0, v0($zero)
    addiu $t9, $zero, 0
    lw    $s1, v1($zero)
    addu  $s2, $s0, $s1         # s0 gap 2 (bypass), s1 gap 0 (stall)
    check $s2, 300, 4

    # a load overwritten by a younger ALU write must not leak the stale load value
    lw    $s3, v0($zero)
    li    $s3, 5
    addu  $s4, $s3, $s3
    check $s4, 10, 5

    # load overwritten by another load: older load's data must not forward
    lw    $s5, v0($zero)
    lw    $s5, v1($zero)
    addu  $s6, $s5, $zero
    check $s6, 200, 6
.endtest
.data
v0: .word 100
v1: .word 200
