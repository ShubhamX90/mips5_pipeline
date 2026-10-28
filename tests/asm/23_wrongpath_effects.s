# 23_wrongpath_effects -- instructions fetched behind a taken branch / jump / jr must
# have NO architectural effect, however dangerous they are: stores (including
# misaligned and out-of-range ones that would fault), loads, `break`, an illegal
# opcode, jal (would clobber $ra) and register writes.
# The two slots behind an EX-resolved redirect are in ID and IF; behind j/jal only IF.
.text
    li    $s0, 0x1111
    li    $ra, 0x77
    li    $t0, 1
    li    $s7, 0

    # --- taken conditional branch: poison in both squashed slots (ID, IF)
    bne   $t0, $zero, T1
    sw    $s0, 100($zero)       # wrong-path store          (in ID)
    break                       # wrong-path break          (in IF)
    sw    $s0, 104($zero)
    .inst 0xFFFFFFFF
T1: lw    $t1, 100($zero)
    check $t1, 0, 1

    bne   $t0, $zero, T2
    break                       # break in ID
    sw    $s0, 100($zero)       # store in IF
    li    $s7, 5
T2: lw    $t1, 100($zero)
    check $t1, 0, 2

    bne   $t0, $zero, T3
    .inst 0xFFFFFFFF            # illegal opcode in ID
    .inst 0xFC000000            # another illegal in IF (opcode 0x3F)
    li    $s7, 5
T3: check $s7, 0, 3

    bne   $t0, $zero, T4
    sw    $s0, 2($zero)         # misaligned store: would raise an address error if executed
    lw    $s1, 0x7FFC($zero)    # out-of-range load: likewise
T4: check $s7, 0, 4

    bne   $t0, $zero, T5
    jal   bad_sub               # would overwrite $ra
    j     bad_sub
T5: check $ra, 0x77, 5

    bne   $t0, $zero, T6
    lui   $s2, 0x1234           # register writes
    addiu $s3, $zero, 9
T6: check $s2, 0, 6
    check $s3, 0, 7

    # --- jal / j: one slot squashed (IF)
    j     T8
    sw    $s0, 108($zero)
    li    $s7, 9
T8: lw    $t1, 108($zero)
    check $t1, 0, 8
    check $s7, 0, 9

    jal   T9s
    break                       # IF slot behind jal
T9s:
    li    $ra, 0x77             # restore after jal

    j     T10
    break
T10:
    j     T11
    .inst 0xFFFFFFFF
T11:
    # --- jr / jalr: two slots squashed
    la    $t2, T12
    jr    $t2
    sw    $s0, 112($zero)
    break
    li    $s7, 3
T12:
    lw    $t1, 112($zero)
    check $t1, 0, 10
    check $s7, 0, 11

    la    $t3, T13
    jalr  $s6, $t3
    sw    $s0, 116($zero)
    .inst 0xFFFFFFFF
T13:
    lw    $t1, 116($zero)
    check $t1, 0, 12

    # --- taken branch whose shadow holds a taken j / jr / branch (squashed control flow)
    bne   $t0, $zero, T14
    j     bad_sub
    j     bad_sub
T14:
    bne   $t0, $zero, T15
    jr    $ra                   # $ra = 0x77, misaligned: would fault if executed
    jr    $ra
T15:
    bne   $t0, $zero, T16
    beq   $zero, $zero, bad_sub
    beq   $zero, $zero, bad_sub
T16:
    check $s7, 0, 13
.endtest
bad_sub:
    li    $s7, 0x666
    break
