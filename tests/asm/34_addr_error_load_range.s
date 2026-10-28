# 34_addr_error_load_range -- lb with a huge effective address (wraps negative) halts with ADDR.
#! expect-cause=addr
#! no-selfcheck
.text
    li    $t0, -4
    li    $s0, 9
    lb    $s0, 0($t0)           # effective address 0xFFFFFFFC
    break
