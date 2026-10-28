# 30_jump_unmapped -- jr into an address beyond instruction memory: the fetch of the
# unmapped word yields ILLEGAL, reported at the jump target.
#! expect-cause=illegal
#! no-selfcheck
.text
    li    $s0, 7
    li    $t0, 0x8000
    jr    $t0
    li    $s0, 8                # wrong path
