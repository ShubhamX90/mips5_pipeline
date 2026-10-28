# matmul -- 8x8 integer matrix multiply C = A*B (A, B from an LCG, 8-bit entries);
# result = sum(C[i][j] * (8i+j+1)).
# Character: triple loop, address arithmetic (sll/addu), two loads + MUL + accumulate per
# inner iteration (load-use into MUL), highly predictable-by-loop but taken backward branches.
.equ N, 8
.text
    la    $s0, matA
    la    $s1, matB
    la    $s2, matC
    li    $t0, 99
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:                            # 128 entries: A (64) then B (64), contiguous
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 16
    andi  $t4, $t4, 0xFF
    sll   $t5, $t1, 2
    addu  $t5, $t5, $s0
    sw    $t4, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, 2 * N * N
    bne   $t6, $zero, gen

    li    $s3, 0                # i
iloop:
    li    $s4, 0                # j
jloop:
    li    $s5, 0                # k
    li    $s6, 0                # acc
kloop:
    sll   $t0, $s3, 3           # i*8
    addu  $t0, $t0, $s5         # + k
    sll   $t0, $t0, 2
    addu  $t0, $t0, $s0
    lw    $t1, 0($t0)           # A[i][k]
    sll   $t2, $s5, 3           # k*8
    addu  $t2, $t2, $s4         # + j
    sll   $t2, $t2, 2
    addu  $t2, $t2, $s1
    lw    $t3, 0($t2)           # B[k][j]
    mul   $t4, $t1, $t3
    addu  $s6, $s6, $t4
    addiu $s5, $s5, 1
    slti  $t5, $s5, N
    bne   $t5, $zero, kloop
    sll   $t0, $s3, 3
    addu  $t0, $t0, $s4
    sll   $t0, $t0, 2
    addu  $t0, $t0, $s2
    sw    $s6, 0($t0)           # C[i][j]
    addiu $s4, $s4, 1
    slti  $t5, $s4, N
    bne   $t5, $zero, jloop
    addiu $s3, $s3, 1
    slti  $t5, $s3, N
    bne   $t5, $zero, iloop

    li    $v0, 0
    li    $t1, 0
    move  $t0, $s2
chk:
    lw    $t2, 0($t0)
    addiu $t3, $t1, 1
    mul   $t4, $t2, $t3
    addu  $v0, $v0, $t4
    addiu $t0, $t0, 4
    addiu $t1, $t1, 1
    slti  $t5, $t1, N * N
    bne   $t5, $zero, chk
    break
.data
matA: .space 256
matB: .space 256
matC: .space 256
