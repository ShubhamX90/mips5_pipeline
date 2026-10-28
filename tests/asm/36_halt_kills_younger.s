# 36_halt_kills_younger -- everything younger than a retiring `break` must be squashed:
# stores directly behind it are in EX/MEM when it reaches WB, and a taken-branch
# shadow behind it is in flight.  Memory and registers must show no trace.
#! no-selfcheck
.text
    li    $t0, 0x55
    sw    $t0, 0($zero)
    li    $t1, 0x99
    break
    sw    $t1, 0($zero)         # in MEM when break is in WB
    sw    $t1, 4($zero)
    li    $s0, 7
    addiu $s1, $s0, 1
