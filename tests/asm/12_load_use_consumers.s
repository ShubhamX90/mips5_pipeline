# 12_load_use_consumers -- load followed immediately by every *kind* of consumer:
# branch (rs, rt), jr, store address, store data, load address, mul.
.text
    # branch operand straight from a load (stall, then branch resolves in EX)
    lw    $t0, five($zero)
    li    $t1, 5
    lw    $t2, five($zero)
    beq   $t2, $t1, b1          # rs from load, rt from li
    li    $s7, 1                # wrong path
b1: check $s7, 0, 1

    lw    $t3, five($zero)
    bne   $t1, $t3, bad1        # rt from load, not taken
    li    $s6, 2
bad1:
    check $s6, 2, 2

    lw    $t4, five($zero)
    bgtz  $t4, b2               # single-register branch on a loaded value
    li    $s7, 1
b2: check $s7, 0, 3

    lw    $t5, neg($zero)
    bltz  $t5, b3
    li    $s7, 1
b3: check $s7, 0, 4

    # jr target loaded from memory immediately before the jump
    lw    $t6, fdest($zero)
    jr    $t6
    li    $s7, 1                # wrong path
dest:
    check $s7, 0, 5

    # jalr with loaded target
    lw    $t7, fcall($zero)
    jalr  $t7
    j     after_call
callee:
    li    $v0, 123
    jr    $ra
after_call:
    check $v0, 123, 6

    # store address from a load, then store data from a load
    lw    $a0, ptr($zero)       # 64
    sw    $t1, 0($a0)           # base depends on load
    lw    $a1, 64($zero)
    check $a1, 5, 7

    lw    $a2, five($zero)
    sw    $a2, 68($zero)        # store data depends on load (MEM->MEM or stall)
    lw    $a3, 68($zero)
    check $a3, 5, 8

    lw    $s0, ptr($zero)
    lw    $s1, 0($s0)           # load address depends on load
    check $s1, 5, 9

    lw    $s2, five($zero)
    mul   $s3, $s2, $s2
    check $s3, 25, 10
.endtest
.data
five:  .word 5
neg:   .word -3
ptr:   .word 64
fdest: .word dest
fcall: .word callee
