# 17_store_load_order -- memory ordering: a younger load must see an older store
# (and only the *older* ones) however close they are, including partial overlaps.
.text
    li    $t0, 0xAABBCCDD
    sw    $t0, 0($zero)
    lw    $t1, 0($zero)         # store in MEM when load in EX
    check $t1, 0xAABBCCDD, 1

    li    $t2, 0x11
    sb    $t2, 1($zero)         # patch one byte of the word
    lw    $t3, 0($zero)
    check $t3, 0xAABB11DD, 2

    li    $t4, 0x2222
    sh    $t4, 2($zero)
    lw    $t5, 0($zero)
    check $t5, 0x222211DD, 3

    # load before a store to the same address sees the OLD value
    lw    $t6, 0($zero)
    li    $t7, -1
    sw    $t7, 0($zero)
    lw    $t8, 0($zero)
    check $t6, 0x222211DD, 4
    check $t8, -1, 5

    # a store sandwiched between two loads of the same address
    lw    $s0, 4($zero)
    sw    $t7, 4($zero)
    lw    $s1, 4($zero)
    check $s0, 0, 6
    check $s1, -1, 7

    # stores to neighbouring words do not interfere
    li    $a0, 1
    li    $a1, 2
    li    $a2, 3
    sw    $a0, 8($zero)
    sw    $a1, 12($zero)
    sw    $a2, 16($zero)
    lw    $a3, 12($zero)
    lw    $v0, 8($zero)
    lw    $v1, 16($zero)
    check $a3, 2, 8
    check $v0, 1, 9
    check $v1, 3, 10

    # store with an address computed by the immediately preceding instruction
    addiu $s2, $zero, 24
    sw    $a2, 0($s2)
    lw    $s3, 24($zero)
    check $s3, 3, 11
.endtest
