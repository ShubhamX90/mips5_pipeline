# 10_r0_hazard -- writes to $0 must never be forwarded or retained.
.text
    addiu $zero, $zero, 5       # architecturally a nop
    addu  $t0, $zero, $zero     # consumer at distance 1 must see 0, not 5
    check $t0, 0, 1

    li    $t1, 7
    ori   $zero, $t1, 0xFF
    subu  $t2, $t1, $zero       # rt = $0 at distance 1
    check $t2, 7, 2

    lui   $zero, 0x1234
    addu  $t3, $zero, $t1       # rs = $0 at distance 1
    check $t3, 7, 3

    addiu $zero, $zero, 9
    nop
    addu  $t4, $zero, $t1       # distance 2 (MEM/WB)
    check $t4, 7, 4

    addiu $zero, $zero, 9
    nop
    nop
    addu  $t5, $zero, $t1       # distance 3 (register-file write-through)
    check $t5, 7, 5

    lw    $zero, word($zero)    # load to $0 ...
    addu  $t6, $zero, $t1       # ... must neither stall nor forward
    check $t6, 7, 6

    jal   fn                    # jal writes $ra only
    check $zero, 0, 7
    j     past
fn:
    addu  $zero, $ra, $ra       # write $0 with a non-zero value
    jr    $ra
past:
    addiu $zero, $zero, 1
    beq   $zero, $zero, take    # must be taken: $0 == $0 == 0
    li    $s7, 1                # wrong path
take:
    check $s7, 0, 8

    mul   $zero, $t1, $t1       # mul to $0
    addu  $t7, $zero, $zero
    check $t7, 0, 9
    sll   $zero, $t1, 3
    or    $t8, $zero, $zero
    check $t8, 0, 10
.endtest
.data
word: .word 0xCAFEBABE
