#! no-selfcheck
# binary_search -- 200 LCG keys searched in a sorted 256-entry table a[i] = 7i+3;
# result = number of keys found.
# Character: log2(N) iterations of load, compare, three-way branch per search; load-use into branch.
.text
    la    $s0, tbl
    li    $t1, 0
fill:
    sll   $t2, $t1, 3
    subu  $t2, $t2, $t1         # 7*i
    addiu $t2, $t2, 3
    sll   $t3, $t1, 2
    addu  $t3, $t3, $s0
    sw    $t2, 0($t3)
    addiu $t1, $t1, 1
    slti  $t4, $t1, 256
    bne   $t4, $zero, fill

    li    $s1, 8675309
    li    $s2, 1664525
    li    $s3, 1013904223
    li    $s4, 200             # keys left
    li    $v0, 0
key:
    mul   $s1, $s1, $s2
    addu  $s1, $s1, $s3
    srl   $t0, $s1, 16
    andi  $t0, $t0, 0x7FF       # key 0..2047
    li    $t1, 0                # lo
    li    $t2, 255              # hi
bs: slt   $t3, $t2, $t1
    bne   $t3, $zero, miss
    addu  $t4, $t1, $t2
    srl   $t4, $t4, 1           # mid
    sll   $t5, $t4, 2
    addu  $t5, $t5, $s0
    lw    $t6, 0($t5)
    beq   $t6, $t0, hit
    slt   $t7, $t6, $t0
    beq   $t7, $zero, golo
    addiu $t1, $t4, 1
    b     bs
golo:
    addiu $t2, $t4, -1
    b     bs
hit:
    addiu $v0, $v0, 1
miss:
    addiu $s4, $s4, -1
    bgtz  $s4, key
    break
.data
tbl: .space 1024
