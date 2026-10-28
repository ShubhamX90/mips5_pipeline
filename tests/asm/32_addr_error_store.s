# 32_addr_error_store -- misaligned sw/sh must not write memory, then halt with ADDR.
#! expect-cause=addr
#! no-selfcheck
.text
    li    $t0, -1
    sw    $t0, 0($zero)         # legal: memory[0] = 0xFFFFFFFF
    li    $t1, 0x12345678
    sh    $t1, 1($zero)         # misaligned halfword store: must NOT modify memory
    sw    $t1, 4($zero)         # younger store: must NOT commit
    break
