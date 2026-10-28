# 39_recursion -- recursive factorial and Fibonacci with a software stack:
# deep call/return chains (jal / lw $ra / jr $ra), saved registers around calls,
# and load-use stalls on $ra restore.
.text
    li    $sp, 0x3F00

    li    $a0, 6
    jal   fact
    check $v0, 720, 1

    li    $a0, 10
    jal   fib
    check $v0, 55, 2

    li    $a0, 1
    jal   fact
    check $v0, 1, 3

    li    $a0, 12
    jal   fact
    check $v0, 479001600, 4
    check $sp, 0x3F00, 5        # stack balanced
.endtest

# int fact(int n) { return n <= 1 ? 1 : n * fact(n-1); }
fact:
    addiu $sp, $sp, -8
    sw    $ra, 4($sp)
    sw    $a0, 0($sp)
    slti  $t0, $a0, 2
    beq   $t0, $zero, fact_rec
    li    $v0, 1
    b     fact_ret
fact_rec:
    addiu $a0, $a0, -1
    jal   fact
    lw    $a0, 0($sp)
    mul   $v0, $v0, $a0         # load-use into mul
fact_ret:
    lw    $ra, 4($sp)
    addiu $sp, $sp, 8
    jr    $ra                   # lw $ra two instructions earlier: MEM/WB bypass

# int fib(int n) { return n < 2 ? n : fib(n-1) + fib(n-2); }
fib:
    addiu $sp, $sp, -12
    sw    $ra, 8($sp)
    sw    $a0, 4($sp)
    slti  $t0, $a0, 2
    beq   $t0, $zero, fib_rec
    move  $v0, $a0
    b     fib_ret
fib_rec:
    addiu $a0, $a0, -1
    jal   fib
    sw    $v0, 0($sp)           # fib(n-1)
    lw    $a0, 4($sp)
    addiu $a0, $a0, -2
    jal   fib
    lw    $t1, 0($sp)
    addu  $v0, $v0, $t1         # load-use
fib_ret:
    lw    $ra, 8($sp)
    lw    $a0, 4($sp)
    addiu $sp, $sp, 12
    jr    $ra
