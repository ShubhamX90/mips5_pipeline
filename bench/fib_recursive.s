#! no-selfcheck
# fib_recursive -- naive recursive fib(17) = 1597 with a software stack.
# Character: call/return dominated: jal, sw/lw of $ra and arguments, lw $ra -> jr $ra,
# data-dependent recursion shape, ~5000 calls.
.text
    li    $sp, 0x3F00
    li    $a0, 17
    jal   fib
    move  $v0, $v0
    break
fib:
    addiu $sp, $sp, -12
    sw    $ra, 8($sp)
    sw    $a0, 4($sp)
    slti  $t0, $a0, 2
    beq   $t0, $zero, rec
    move  $v0, $a0
    b     ret
rec:
    addiu $a0, $a0, -1
    jal   fib
    sw    $v0, 0($sp)
    lw    $a0, 4($sp)
    addiu $a0, $a0, -2
    jal   fib
    lw    $t1, 0($sp)
    addu  $v0, $v0, $t1
ret:
    lw    $ra, 8($sp)
    lw    $a0, 4($sp)
    addiu $sp, $sp, 12
    jr    $ra
