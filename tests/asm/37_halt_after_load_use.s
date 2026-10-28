# 37_halt_after_load_use -- a faulting instruction that is itself stalled by a load-use
# hazard: the stall happens (older load), then the fault is raised on the held
# instruction.  Exercises event accounting around halting instructions.
#! expect-cause=addr
#! no-selfcheck
.text
    lw    $t0, ptr($zero)       # 0x3FFF (misaligned base)
    lw    $s0, 0($t0)           # stalled on t0, then faults (misaligned)
    li    $s1, 5
    break
.data
ptr: .word 0x3FFF
