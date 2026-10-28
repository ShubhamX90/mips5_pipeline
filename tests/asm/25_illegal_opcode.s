# 25_illegal_opcode -- an undefined primary opcode halts with ILLEGAL, does not retire,
# and nothing younger commits (the register write and store after it must not happen).
#! expect-cause=illegal
#! no-selfcheck
.text
    li    $s0, 0x1234
    sw    $s0, 0($zero)
    li    $s1, 0x5678
    .inst 0xFC000000            # opcode 0x3F: undefined
    li    $s2, 0xDEAD           # must not commit
    sw    $s2, 4($zero)         # must not commit
    break
