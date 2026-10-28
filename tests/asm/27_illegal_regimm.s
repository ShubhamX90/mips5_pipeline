# 27_illegal_regimm -- REGIMM with an unsupported rt (bltzal=0x10) halts with ILLEGAL.
#! expect-cause=illegal
#! no-selfcheck
.text
    li    $t0, -1
    .inst 0x05100002            # REGIMM rs=$t0.. rt=0x10 (bltzal): not implemented
    li    $s0, 1                # must not commit
    break
