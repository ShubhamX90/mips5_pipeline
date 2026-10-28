#! no-selfcheck
# sieve -- Sieve of Eratosthenes on 1024 byte flags; result = number of primes < 1024 (172).
# Character: byte stores with stride, nested loops, inner loop trip counts shrink with i.
.equ N, 1024
.text
    la    $s0, flags
    li    $s1, 2                # i
outer:
    mul   $t0, $s1, $s1         # i*i
    slti  $t1, $t0, N
    beq   $t1, $zero, count
    addu  $t2, $s0, $s1
    lbu   $t3, 0($t2)
    bne   $t3, $zero, next      # composite: skip
    li    $t4, 1
mark:
    addu  $t5, $s0, $t0
    sb    $t4, 0($t5)
    addu  $t0, $t0, $s1
    slti  $t1, $t0, N
    bne   $t1, $zero, mark
next:
    addiu $s1, $s1, 1
    b     outer
count:
    li    $v0, 0
    li    $t0, 2
cl: addu  $t2, $s0, $t0
    lbu   $t3, 0($t2)
    bne   $t3, $zero, notp
    addiu $v0, $v0, 1
notp:
    addiu $t0, $t0, 1
    slti  $t1, $t0, N
    bne   $t1, $zero, cl
    break
.data
flags: .space 1024
