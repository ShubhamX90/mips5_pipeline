# bubble_sort -- 64 LCG-generated words sorted ascending; result = sum((i+1)*a[i]).
# Character: data-dependent swap branch (unpredictable), lw/lw/compare chains with
# load-use stalls, stores in the shadow of branches.
.equ N, 64
.text
    la    $s0, arr
    li    $t0, 12345            # LCG state
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 16
    andi  $t4, $t4, 0xFFF
    sll   $t5, $t1, 2
    addu  $t5, $t5, $s0
    sw    $t4, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, N
    bne   $t6, $zero, gen

    li    $s1, N - 1            # passes remaining
outer:
    li    $t1, 0
    move  $s2, $s0
inner:
    lw    $t2, 0($s2)
    lw    $t3, 4($s2)
    slt   $t4, $t3, $t2
    beq   $t4, $zero, noswap
    sw    $t3, 0($s2)
    sw    $t2, 4($s2)
noswap:
    addiu $s2, $s2, 4
    addiu $t1, $t1, 1
    bne   $t1, $s1, inner
    addiu $s1, $s1, -1
    bgtz  $s1, outer

    li    $v0, 0
    li    $t1, 0
    move  $s2, $s0
sum:
    lw    $t2, 0($s2)
    addiu $t3, $t1, 1
    mul   $t4, $t2, $t3
    addu  $v0, $v0, $t4
    addiu $s2, $s2, 4
    addiu $t1, $t1, 1
    slti  $t6, $t1, N
    bne   $t6, $zero, sum
    break
.data
arr: .space 256
