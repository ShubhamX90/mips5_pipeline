# 21_jumps -- j, jal, jr: jump targets, link address, nested calls with a stack.
.text
    li    $sp, 0x3F00
    li    $s7, 0

    j     skip1
    li    $s7, 1                # wrong path
    li    $s7, 2
skip1:
    check $s7, 0, 1

    # jal link register = address of the following instruction (no delay slot)
    la    $t0, ret1
    jal   f1
ret1:
    checkr $ra, $t0, 2

    # nested calls, $ra saved/restored through the stack: lw $ra; jr $ra (load-use into jr)
    li    $a0, 5
    jal   outer_fn
    check $v0, 5 * 2 + 3 + 1, 3

    # call in a loop
    li    $s0, 0
    li    $s1, 0
cl: jal   inc_s0
    addiu $s1, $s1, 1
    slti  $t1, $s1, 10
    bne   $t1, $zero, cl
    check $s0, 10, 4

    # jr to a computed address
    la    $t2, target1
    jr    $t2
    li    $s7, 1
target1:
    check $s7, 0, 5

    # back-to-back jumps
    j     j2
j3: j     j4
    li    $s7, 1
j2: j     j3
    li    $s7, 1
j4: check $s7, 0, 6

    # callee whose very first instruction reads $ra written by the jal
    la    $t3, use_ra_ret
    jal   use_ra
use_ra_ret:
    check $v1, 1, 7
    j     end
f1:
    jr    $ra
outer_fn:
    addiu $sp, $sp, -8
    sw    $ra, 4($sp)
    sw    $a0, 0($sp)
    sll   $a0, $a0, 1           # 2*a0
    jal   inner_fn              # returns a0 + 3
    lw    $a0, 0($sp)
    lw    $ra, 4($sp)
    addiu $sp, $sp, 8
    addiu $v0, $v0, 1           # +1
    jr    $ra
inner_fn:
    addiu $v0, $a0, 3
    jr    $ra
inc_s0:
    addiu $s0, $s0, 1
    jr    $ra
use_ra:
    xor   $v1, $ra, $t3         # first instruction of the callee consumes $ra (EX/MEM fwd of the link value)
    sltiu $v1, $v1, 1           # 1 iff $ra == use_ra_ret
    jr    $ra
end:
.endtest
