# 33_addr_error_range -- store beyond the end of data memory halts with ADDR (suppressed write).
#! expect-cause=addr
#! no-selfcheck
.text
    li    $t0, 0x4000           # first byte past the 16 KiB data memory
    li    $t1, 0x55
    sb    $t1, 0($t0)
    break
