# collatz -- total Collatz steps for n = 1..250; result = sum of step counts.
# Character: parity branch with essentially random outcome each step; short dependent ALU chains.
.text
    li    $v0, 0
    li    $s0, 1
    li    $s1, 251
outer:
    move  $t0, $s0
    li    $t1, 1
cz: beq   $t0, $t1, done
    andi  $t2, $t0, 1
    beq   $t2, $zero, even
    addu  $t3, $t0, $t0
    addu  $t0, $t3, $t0
    addiu $t0, $t0, 1           # 3n+1
    b     step
even:
    srl   $t0, $t0, 1
step:
    addiu $v0, $v0, 1
    b     cz
done:
    addiu $s0, $s0, 1
    bne   $s0, $s1, outer
    break
