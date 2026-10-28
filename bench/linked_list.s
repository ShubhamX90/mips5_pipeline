# linked_list -- 128 nodes {next ptr, value} wired as next(i) = (37i+1) mod 128; 1024 hops
# starting at node 0 sum the node values (value(i) = 3i+1).
# Character: pure pointer chasing -- every lw's address depends on the previous lw (load-use
# stall on every hop) and the loaded pointer is the loop-carried dependence.
.text
    la    $s0, nodes
    li    $t1, 0
build:
    sll   $t2, $t1, 5           # 32*i
    sll   $t3, $t1, 2           # 4*i
    addu  $t2, $t2, $t3         # 36*i
    addu  $t2, $t2, $t1         # 37*i
    addiu $t2, $t2, 1
    andi  $t2, $t2, 127         # next index
    sll   $t2, $t2, 3
    addu  $t2, $t2, $s0         # &node[next]
    sll   $t4, $t1, 3
    addu  $t4, $t4, $s0         # &node[i]
    sw    $t2, 0($t4)
    sll   $t5, $t1, 1
    addu  $t5, $t5, $t1         # 3i
    addiu $t5, $t5, 1
    sw    $t5, 4($t4)
    addiu $t1, $t1, 1
    slti  $t6, $t1, 128
    bne   $t6, $zero, build

    move  $t0, $s0              # cursor = node 0
    li    $v0, 0
    li    $s1, 1024
walk:
    lw    $t1, 4($t0)           # value
    lw    $t0, 0($t0)           # next pointer
    addu  $v0, $v0, $t1
    addiu $s1, $s1, -1
    bgtz  $s1, walk
    break
.data
nodes: .space 1024
