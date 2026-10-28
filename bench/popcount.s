#! no-selfcheck
# popcount -- Kernighan bit counting over 256 random 32-bit words; result = total set bits.
# Character: data-dependent inner trip count (avg 16), a 3-instruction dependent chain
# (addiu / and / bne) with a taken backward branch each time.
.text
    la    $s0, words
    li    $t0, 1337
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    sll   $t5, $t1, 2
    addu  $t5, $t5, $s0
    sw    $t0, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, 256
    bne   $t6, $zero, gen

    li    $v0, 0
    li    $t1, 0
    move  $t8, $s0
wl: lw    $t4, 0($t8)
    beq   $t4, $zero, wz
pc: addiu $t5, $t4, -1
    and   $t4, $t4, $t5
    addiu $v0, $v0, 1
    bne   $t4, $zero, pc
wz: addiu $t8, $t8, 4
    addiu $t1, $t1, 1
    slti  $t6, $t1, 256
    bne   $t6, $zero, wl
    break
.data
words: .space 1024
