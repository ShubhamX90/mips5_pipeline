# 29_fall_off_end -- no terminating break: execution runs past the program image into
# instruction-memory locations that were never loaded.  They read as an all-ones
# (illegal) word, so the core halts with ILLEGAL at the first address after the image.
#! expect-cause=illegal
#! no-selfcheck
.text
    li    $v0, 1
    addiu $v0, $v0, 1
    addiu $v0, $v0, 1
