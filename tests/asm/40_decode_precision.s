# 40_decode_precision -- the load-use interlock must be *precise*: it may only fire when the
# instruction in ID really reads the loaded register.  Here the instruction behind a load has a
# register-looking field that the instruction does not read:
#   sll/srl/sra  : the rs field is reserved (ignored by the decoder, "should be zero")
#   lui          : the rs field is reserved
# These are encoded by hand (.inst) with the reserved field set to the load's destination
# register.  A merely "field matches" interlock would insert a spurious bubble; the cycle-exact
# performance model in the regression flags any such imprecision.
.text
    li    $t2, 0x10
    li    $s0, 0

    lw    $t0, word($zero)
    .inst 0x010A48C0            # sll $t1,$t2,3   with reserved rs = $t0
    check $t1, 0x80, 1

    lw    $t0, word($zero)
    .inst 0x010A4882            # srl $t1,$t2,2   with reserved rs = $t0
    check $t1, 4, 2

    lw    $t0, word($zero)
    .inst 0x010A4843            # sra $t1,$t2,1   with reserved rs = $t0
    check $t1, 8, 3

    lw    $t0, word($zero)
    .inst 0x3D090005            # lui $t1,5       with reserved rs = $t0
    check $t1, 0x50000, 4

    # dest field equal to the load's dest but not read (I-type destination, lui destination)
    lw    $t0, word($zero)
    .inst 0x3D080005            # lui $t0,5  (rs reserved = $t0, rt = dest = $t0)
    check $t0, 0x50000, 5

    # a store reads rt: with MEM->MEM forwarding no stall, otherwise one stall (build-dependent,
    # architecturally identical)
    lw    $t3, word($zero)
    sw    $t3, 8($zero)
    lw    $t4, 8($zero)
    check $t4, 0x1234, 6
.endtest
.data
word: .word 0x1234
