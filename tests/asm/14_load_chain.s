# 14_load_chain -- pointer chasing: each load's address is the previous load's data
# (a load-use stall per hop), and the loaded pointer feeds a branch.
.text
    lw    $t0, head($zero)
    li    $s0, 0                # sum
    li    $s1, 0                # node count
loop:
    beqz  $t0, done             # load-use into branch
    lw    $t1, 4($t0)           # value
    addu  $s0, $s0, $t1         # load-use into add
    lw    $t0, 0($t0)           # next pointer (address depends on previous load)
    addiu $s1, $s1, 1
    b     loop
done:
    check $s0, 100, 1
    check $s1, 4, 2

    # dependent load chain without any ALU op in between
    lw    $a0, head($zero)
    lw    $a0, 0($a0)           # n1
    lw    $a0, 0($a0)           # n2
    lw    $a0, 0($a0)           # n3
    lw    $a1, 4($a0)           # n3.value
    check $a1, 40, 3
    lw    $a2, 0($a0)           # n3.next = 0
    check $a2, 0, 4
.endtest
.data
head: .word n0
n0:   .word n1, 10
n1:   .word n2, 20
n2:   .word n3, 30
n3:   .word 0, 40
