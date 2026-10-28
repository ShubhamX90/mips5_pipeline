# 00_smoke: minimal end-to-end sanity -- one op per class
.text
    addiu $t0, $zero, 5
    addiu $t1, $zero, 7
    addu  $t2, $t0, $t1       # forwarding chain
    check $t2, 12, 1
    sw    $t2, 0($zero)
    lw    $t3, 0($zero)
    check $t3, 12, 2
    beq   $t2, $t3, ok
    check $zero, 1, 3         # wrong path: must not run
ok:
    jal   func
    check $v0, 99, 4
    j     done
func:
    li    $v0, 99
    jr    $ra
done:
.endtest
