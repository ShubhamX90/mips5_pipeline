# gcd -- Euclid by repeated subtraction over 40 LCG pairs (values 1..1024); result = sum of gcds.
# Character: branch-dominated, data-dependent direction changes every few iterations
# (pessimal for a static predict-not-taken pipeline).
.text
    li    $s0, 4242
    li    $s1, 1664525
    li    $s2, 1013904223
    li    $s3, 40
    li    $v0, 0
pair:
    mul   $s0, $s0, $s1
    addu  $s0, $s0, $s2
    srl   $t0, $s0, 16
    andi  $t0, $t0, 0x3FF
    addiu $t0, $t0, 1           # a
    mul   $s0, $s0, $s1
    addu  $s0, $s0, $s2
    srl   $t1, $s0, 16
    andi  $t1, $t1, 0x3FF
    addiu $t1, $t1, 1           # b
g:  beq   $t0, $t1, gdone
    slt   $t2, $t1, $t0         # b < a ?
    beq   $t2, $zero, bgta
    subu  $t0, $t0, $t1
    b     g
bgta:
    subu  $t1, $t1, $t0
    b     g
gdone:
    addu  $v0, $v0, $t0
    addiu $s3, $s3, -1
    bgtz  $s3, pair
    break
