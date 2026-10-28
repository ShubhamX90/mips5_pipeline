# 26_illegal_funct -- an undefined SPECIAL funct (0x2C) halts with ILLEGAL. (27 and 28 cover
# the undefined REGIMM rt and SPECIAL2 funct cases; a halt is terminal, so one program each.)
#! expect-cause=illegal
#! no-selfcheck
.text
    li    $t0, 3
    li    $t1, 4
    addu  $t2, $t0, $t1
    .inst 0x0109502C            # SPECIAL, funct 0x2C undefined (looks like 'dadd')
    addiu $t2, $t2, 1           # must not commit
    break
