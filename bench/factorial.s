#! no-selfcheck
# factorial -- sum of n! (mod 2^32) for n = 1..20 using MUL.
# Character: MUL result feeds the next MUL directly; short outer/inner loops.
.text
    li    $v0, 0
    li    $s0, 1                # n
    li    $s2, 21
outer:
    li    $t0, 1                # n!
    li    $t1, 1                # k
inner:
    mul   $t0, $t0, $t1
    addiu $t1, $t1, 1
    ble   $t1, $s0, inner
    addu  $v0, $v0, $t0
    addiu $s0, $s0, 1
    bne   $s0, $s2, outer
    break
