# 20_loops -- loops of different shapes: every iteration but the last takes a
# backward branch (2-cycle flush each), with data hazards inside the bodies.
.text
    # sum 1..100
    li    $t0, 0
    li    $t1, 1
    li    $t2, 100
l1: addu  $t0, $t0, $t1
    addiu $t1, $t1, 1
    ble   $t1, $t2, l1
    check $t0, 5050, 1

    # nested loops: 10 x 10
    li    $s0, 0
    li    $t3, 0
outer:
    li    $t4, 0
inner:
    addiu $s0, $s0, 1
    addiu $t4, $t4, 1
    slti  $t5, $t4, 10
    bne   $t5, $zero, inner
    addiu $t3, $t3, 1
    slti  $t5, $t3, 10
    bne   $t5, $zero, outer
    check $s0, 100, 2

    # count down with bgtz, single-instruction body
    li    $t6, 50
    li    $s1, 0
l3: addiu $s1, $s1, 2
    addiu $t6, $t6, -1
    bgtz  $t6, l3
    check $s1, 100, 3

    # array sum with load-use inside the loop
    li    $t7, 0                # index (bytes)
    li    $s2, 0                # sum
    li    $t8, 64               # 16 words
l4: lw    $t9, arr($t7)
    addu  $s2, $s2, $t9         # load-use stall every iteration
    addiu $t7, $t7, 4
    bne   $t7, $t8, l4
    check $s2, 136, 4

    # do-while that runs exactly once (branch never taken)
    li    $s3, 0
l5: addiu $s3, $s3, 1
    bne   $zero, $zero, l5
    check $s3, 1, 5

    # loop with a data-dependent exit: first power of two >= 1000
    li    $s4, 1
l6: sll   $s4, $s4, 1
    slti  $a0, $s4, 1000
    bne   $a0, $zero, l6
    check $s4, 1024, 6

    # find max of array with a conditional move idiom (taken/not-taken mix)
    li    $t7, 0
    li    $s5, -1
l7: lw    $t9, arr($t7)
    slt   $a1, $s5, $t9
    beq   $a1, $zero, skip
    move  $s5, $t9
skip:
    addiu $t7, $t7, 4
    bne   $t7, $t8, l7
    check $s5, 16, 7
.endtest
.data
arr: .word 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
