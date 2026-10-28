# 28_illegal_special2 -- SPECIAL2 with funct other than MUL halts with ILLEGAL (e.g. clz).
#! expect-cause=illegal
#! no-selfcheck
.text
    li    $t0, 0x100
    .inst 0x71094820            # SPECIAL2 funct 0x20 (clz): not implemented
    li    $s0, 1                # must not commit
    break
