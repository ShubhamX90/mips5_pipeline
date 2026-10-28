# mini_vm -- bytecode interpreter: 256 random opcodes (0..3) dispatched 4096 times through a
# jump table (lbu -> sll -> lw -> jr), updating an accumulator; result = final accumulator.
#   op0: acc += 3   op1: acc ^= 0x55   op2: acc = rotl(acc,1)   op3: acc -= 7
# Character: indirect jumps with a 3-deep load-use chain feeding every jr; random targets.
.text
    la    $s0, code
    li    $t0, 99991
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 20
    andi  $t4, $t4, 3
    addu  $t5, $s0, $t1
    sb    $t4, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, 256
    bne   $t6, $zero, gen

    li    $s1, 0                # pc into code
    li    $s2, 4096             # dispatches left
    li    $v0, 1                # accumulator
dispatch:
    addu  $t5, $s0, $s1
    lbu   $t4, 0($t5)
    sll   $t4, $t4, 2
    lw    $t6, jtab($t4)
    jr    $t6
op0:
    addiu $v0, $v0, 3
    j     next
op1:
    xori  $v0, $v0, 0x55
    j     next
op2:
    sll   $t7, $v0, 1
    srl   $t8, $v0, 31
    or    $v0, $t7, $t8
    j     next
op3:
    addiu $v0, $v0, -7
next:
    addiu $s1, $s1, 1
    andi  $s1, $s1, 255
    addiu $s2, $s2, -1
    bgtz  $s2, dispatch
    break
.data
jtab: .word op0, op1, op2, op3
.org 64
code: .space 256
