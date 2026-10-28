# 31_addr_error_load -- misaligned lw halts with ADDR; the load does not retire and
# the destination register keeps its old value.
#! expect-cause=addr
#! no-selfcheck
.text
    li    $s0, 0x1111
    li    $t0, 2
    lw    $s0, 0($t0)           # misaligned word load at 0x2
    li    $s1, 0x2222           # must not commit
    break
