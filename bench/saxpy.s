# saxpy -- y[i] = 3*x[i] + y[i] over 256 elements (streaming); result = sum(y).
# Character: no branches inside the body besides the loop, two loads + MUL + store;
# regular, load-use heavy, high ILP-friendliness.
.equ N, 256
.text
    la    $s0, xs
    la    $s1, ys
    li    $t0, 5
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 16
    andi  $t4, $t4, 0xFF
    sll   $t5, $t1, 2
    addu  $t6, $t5, $s0
    sw    $t4, 0($t6)
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 16
    andi  $t4, $t4, 0xFF
    addu  $t6, $t5, $s1
    sw    $t4, 0($t6)
    addiu $t1, $t1, 1
    slti  $t7, $t1, N
    bne   $t7, $zero, gen

    li    $s2, 3
    li    $t1, 0
    move  $t8, $s0
    move  $t9, $s1
axpy:
    lw    $t4, 0($t8)
    lw    $t5, 0($t9)
    mul   $t4, $t4, $s2
    addu  $t5, $t5, $t4
    sw    $t5, 0($t9)
    addiu $t8, $t8, 4
    addiu $t9, $t9, 4
    addiu $t1, $t1, 1
    slti  $t7, $t1, N
    bne   $t7, $zero, axpy

    li    $v0, 0
    li    $t1, 0
    move  $t9, $s1
red:
    lw    $t5, 0($t9)
    addu  $v0, $v0, $t5
    addiu $t9, $t9, 4
    addiu $t1, $t1, 1
    slti  $t7, $t1, N
    bne   $t7, $zero, red
    break
.data
xs: .space 1024
ys: .space 1024
