# memcpy_strlen -- build a 400-byte NUL-terminated string from an LCG, strlen it, copy it
# byte by byte, then checksum the copy; result = strlen + sum(bytes of copy).
# Character: lb/lbu/sb streams, byte loop-carried pointers, branch on loaded byte (load-use into branch).
.text
    la    $s0, src
    la    $s1, dst
    li    $t0, 31337
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 16
    andi  $t4, $t4, 0x7F
    ori   $t4, $t4, 1           # never zero
    addu  $t5, $s0, $t1
    sb    $t4, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, 400
    bne   $t6, $zero, gen
    addu  $t5, $s0, $t1
    sb    $zero, 0($t5)         # terminator

    move  $t0, $s0              # strlen
    li    $s2, 0
sl: lbu   $t1, 0($t0)
    beq   $t1, $zero, sl_done   # load-use into branch
    addiu $s2, $s2, 1
    addiu $t0, $t0, 1
    b     sl
sl_done:

    move  $t0, $s0              # memcpy (including terminator)
    move  $t2, $s1
cp: lbu   $t1, 0($t0)
    sb    $t1, 0($t2)           # lbu -> sb data (MEM->MEM forwarding case)
    addiu $t0, $t0, 1
    addiu $t2, $t2, 1
    bne   $t1, $zero, cp

    move  $v0, $s2              # checksum
    move  $t0, $s1
sm: lbu   $t1, 0($t0)
    addu  $v0, $v0, $t1
    addiu $t0, $t0, 1
    bne   $t1, $zero, sm
    break
.data
src: .space 408
dst: .space 408
