# fib_iter -- iterative Fibonacci, 100 repetitions of fib(40).
# Character: tight loop, register-only, every instruction depends on the previous
# one (forwarding-bound), one taken backward branch per iteration.
.text
    li    $s0, 100
outer:
    li    $t0, 0
    li    $t1, 1
    li    $t2, 40
loop:
    addu  $t3, $t0, $t1
    move  $t0, $t1
    move  $t1, $t3
    addiu $t2, $t2, -1
    bgtz  $t2, loop
    addiu $s0, $s0, -1
    bgtz  $s0, outer
    move  $v0, $t0
    break
