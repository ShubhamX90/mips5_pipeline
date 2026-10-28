# 13_load_store_interplay -- loads feeding stores in every role, store/load ordering.
# lw->sw data is the case MEM->MEM forwarding removes the stall for; lw->sw base
# always stalls.  Two builds (with/without MEM_MEM_FWD) must agree architecturally.
.text
    lw    $t0, a($zero)
    sw    $t0, b($zero)         # store data = just-loaded value
    lw    $t1, b($zero)
    check $t1, 0x11223344, 1

    lw    $t2, ptr($zero)       # t2 = 64
    sw    $t2, 0($t2)           # base AND data from the load
    lw    $t3, 64($zero)
    check $t3, 64, 2

    # store data from a load, with an unrelated instruction between (MEM/WB fwd)
    lw    $t4, a($zero)
    addiu $t5, $zero, 1
    sw    $t4, 72($zero)
    lw    $t6, 72($zero)
    check $t6, 0x11223344, 3

    # load, ALU op on it, store the ALU result (EX/MEM fwd of store data)
    lw    $s0, a($zero)
    srl   $s1, $s0, 16
    sw    $s1, 76($zero)
    lw    $s2, 76($zero)
    check $s2, 0x1122, 4

    # two stores to the same word, then a load: last writer wins
    li    $a0, 1
    li    $a1, 2
    sw    $a0, 80($zero)
    sw    $a1, 80($zero)
    lw    $a2, 80($zero)
    check $a2, 2, 5

    # store immediately followed by a load of the same address (no stall needed)
    li    $a3, 0x7777
    sw    $a3, 84($zero)
    lw    $v0, 84($zero)
    check $v0, 0x7777, 6

    # load -> store -> load chain, each depends on the previous
    lw    $v1, a($zero)
    sw    $v1, 88($zero)
    lw    $t7, 88($zero)
    sw    $t7, 92($zero)
    lw    $t8, 92($zero)
    check $t8, 0x11223344, 7

    # loaded value used as store data for a *different* register's store (same reg numbers differ)
    lw    $t9, a($zero)
    sw    $zero, 96($zero)
    sw    $t9, 100($zero)
    lw    $s3, 100($zero)
    lw    $s4, 96($zero)
    check $s3, 0x11223344, 8
    check $s4, 0, 9

    # sub-word store of a just-loaded register
    lw    $s5, a($zero)
    sb    $s5, 104($zero)       # low byte 0x44
    lw    $s5, a($zero)
    sh    $s5, 106($zero)       # low half 0x3344
    lw    $s6, 104($zero)
    check $s6, 0x33440044, 10
.endtest
.data
a:   .word 0x11223344
b:   .word 0
.align 4
ptr: .word 64
.space 128
