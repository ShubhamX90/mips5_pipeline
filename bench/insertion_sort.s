#! no-selfcheck
# insertion_sort -- 64 LCG words (10-bit), insertion sort; result = sum((i+1)*a[i]).
# Character: inner while-loop with load, compare, shift-store; mix of taken/not-taken.
.equ N, 64
.text
    la    $s0, arr
    li    $t0, 777
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 12
    andi  $t4, $t4, 0x3FF
    sll   $t5, $t1, 2
    addu  $t5, $t5, $s0
    sw    $t4, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, N
    bne   $t6, $zero, gen

    li    $s1, 1                # i
iloop:
    sll   $t0, $s1, 2
    addu  $t0, $t0, $s0
    lw    $t1, 0($t0)           # key
    addiu $s2, $s1, -1          # j
jloop:
    bltz  $s2, jdone
    sll   $t2, $s2, 2
    addu  $t2, $t2, $s0
    lw    $t3, 0($t2)           # a[j]
    slt   $t4, $t1, $t3         # key < a[j]
    beq   $t4, $zero, jdone
    sw    $t3, 4($t2)           # a[j+1] = a[j]
    addiu $s2, $s2, -1
    b     jloop
jdone:
    addiu $t5, $s2, 1
    sll   $t5, $t5, 2
    addu  $t5, $t5, $s0
    sw    $t1, 0($t5)
    addiu $s1, $s1, 1
    slti  $t6, $s1, N
    bne   $t6, $zero, iloop

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
