# crc32 -- bitwise CRC-32 (poly 0xEDB88320) over 128 LCG bytes; result = final CRC.
# Character: shift/xor ALU chain with a data-dependent branch on the low bit for each of
# 1024 bits (about half taken, unpredictable).
.text
    la    $s0, buf
    li    $t0, 2024
    li    $t2, 1664525
    li    $t3, 1013904223
    li    $t1, 0
gen:
    mul   $t0, $t0, $t2
    addu  $t0, $t0, $t3
    srl   $t4, $t0, 16
    addu  $t5, $s0, $t1
    sb    $t4, 0($t5)
    addiu $t1, $t1, 1
    slti  $t6, $t1, 128
    bne   $t6, $zero, gen

    li    $v0, -1               # crc = 0xFFFFFFFF
    li    $s1, 0xEDB88320
    li    $t1, 0
byte:
    addu  $t5, $s0, $t1
    lbu   $t4, 0($t5)
    xor   $v0, $v0, $t4
    li    $t7, 8
bit:
    andi  $t8, $v0, 1
    srl   $v0, $v0, 1
    beq   $t8, $zero, nox
    xor   $v0, $v0, $s1
nox:
    addiu $t7, $t7, -1
    bgtz  $t7, bit
    addiu $t1, $t1, 1
    slti  $t6, $t1, 128
    bne   $t6, $zero, byte
    nor   $v0, $v0, $zero       # ~crc
    break
.data
buf: .space 128
