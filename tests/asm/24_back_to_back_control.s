# 24_back_to_back_control -- consecutive control-flow instructions and every
# redirect-priority corner: branch at a branch target, jump at a branch target,
# not-taken branch followed by a j (ID redirect while EX does not), TAKEN branch
# followed by a j (EX redirect must win over the j in ID), jal in a taken branch's
# shadow (must not write $ra), jr followed by a jump.
.text
    li    $s7, 0
    li    $ra, 0x44

    beq   $zero, $zero, A       # taken
    li    $s7, 1
A:  beq   $zero, $zero, B       # branch exactly at the target of a branch
    li    $s7, 1
B:  j     C                     # jump exactly at the target of a branch
    li    $s7, 1
C:  beq   $zero, $zero, D       # branch exactly at the target of a jump
    li    $s7, 1
D:  check $s7, 0, 1

    # not-taken branch immediately followed by j: ID redirect, EX does not
    bne   $zero, $zero, X1
    j     E
    li    $s7, 1
X1: li    $s7, 1
E:  check $s7, 0, 2

    # TAKEN branch immediately followed by j: both redirect in the same cycle,
    # the branch (older) wins and the j (squashed) must not redirect
    beq   $zero, $zero, F
    j     G
    li    $s7, 1
G:  li    $s7, 1                # only reachable if the j wrongly redirected
F:  check $s7, 0, 3

    # TAKEN branch followed by jal: jal squashed, $ra untouched
    beq   $zero, $zero, H
    jal   G
    li    $s7, 1
H:  check $ra, 0x44, 4
    check $s7, 0, 5

    # jr followed immediately by j
    la    $t0, I
    jr    $t0
    j     G
    li    $s7, 1
I:  check $s7, 0, 6

    # chain of ten taken branches, each at the previous target
    beq $zero,$zero,c1
    li  $s7, 1
c1: beq $zero,$zero,c2
    li  $s7, 1
c2: beq $zero,$zero,c3
    li  $s7, 1
c3: beq $zero,$zero,c4
    li  $s7, 1
c4: beq $zero,$zero,c5
    li  $s7, 1
c5: beq $zero,$zero,c6
    li  $s7, 1
c6: beq $zero,$zero,c7
    li  $s7, 1
c7: beq $zero,$zero,c8
    li  $s7, 1
c8: beq $zero,$zero,c9
    li  $s7, 1
c9: beq $zero,$zero,c10
    li  $s7, 1
c10:
    check $s7, 0, 7

    # alternating taken / not-taken in a tight loop
    li    $s0, 0
    li    $s1, 0
alt:
    andi  $t1, $s0, 1
    beq   $t1, $zero, even
    addiu $s1, $s1, 100         # odd iterations
    b     cont
even:
    addiu $s1, $s1, 1           # even iterations
cont:
    addiu $s0, $s0, 1
    slti  $t2, $s0, 10
    bne   $t2, $zero, alt
    check $s1, 5 * 100 + 5 * 1, 8

    # a branch directly after a load whose data decides it (stall + redirect interplay)
    lw    $t3, one($zero)
    bne   $t3, $zero, J
    li    $s7, 1
J:  check $s7, 0, 9

    # load-use stall on a branch that is itself in the shadow of nothing, followed by j
    lw    $t4, zero($zero)
    beq   $t4, $zero, K
    li    $s7, 1
K:  j     L
    li    $s7, 1
L:  check $s7, 0, 10

    # jal directly followed by jal-target branch back to caller
    jal   M
    check $s6, 5, 11
    j     N
M:  li    $s6, 5
    beq   $zero, $zero, Mret
    li    $s6, 6
Mret:
    jr    $ra
N:
.endtest
.data
one:  .word 1
zero: .word 0
