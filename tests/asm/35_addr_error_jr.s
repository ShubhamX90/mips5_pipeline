# 35_addr_error_jr -- jr/jalr to a non-word-aligned target raises ADDR on the jump itself
# (no redirect, no link register write).
#! expect-cause=addr
#! no-selfcheck
.text
    li    $ra, 0x11
    li    $t0, 6
    jalr  $s0, $t0              # target 0x6 is misaligned; $s0 must stay 0
    li    $s1, 1                # must not commit
    break
