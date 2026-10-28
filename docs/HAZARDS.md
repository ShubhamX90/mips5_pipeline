# Hazard handling: specification and correctness arguments

This document states exactly what the pipeline does for every hazard class, why it is correct, and which
properties the verification environment enforces. Cycle numbers count the cycle in which an instruction occupies
the named stage; `IF ID EX MEM WB` are written `F D X M W`.

## 1. Data hazards (RAW)

Only read-after-write hazards exist: registers are written in program order in WB, and reads happen in ID/EX, so
WAR and WAW cannot occur in an in-order single-issue pipeline.

Let *d* be the distance in dynamic instructions between producer **P** and consumer **C** (d = 1 ⇒ adjacent).

| d | where is P when C is in EX? | mechanism | stall |
|---:|---|---|---:|
| 1 | MEM (P in EX/MEM) | **EX/MEM → EX** forward (ALU result / link address) | 0 |
| 1, P = load | MEM, data not yet read | **interlock**, then MEM/WB → EX | **1** |
| 2 | WB (P in MEM/WB) | **MEM/WB → EX** forward (ALU result or load data) | 0 |
| 3 | done (P wrote the RF in the cycle C was in ID) | **register-file write-through** | 0 |
| ≥ 4 | done | ordinary RF read | 0 |

```text
 d=1 ALU  addu $t1,$t0,$t0 ; addu $t2,$t1,$t1          F D X M W
                                                          F D X M W     t1 forwarded EX/MEM→EX
 d=1 load lw   $t0,0($a0)  ; addu $t1,$t0,$t0           F D X M W
                                                          F D D X M W   one bubble in EX; t0 forwarded MEM/WB→EX
 d=3      addu $t0,...     ; (x) ; (y) ; addu $t1,$t0   F D X M W
                                                                F D X M W   P in WB while C in ID: regfile bypass
```

### Forwarding network
`forwarding_unit` selects, independently for each ALU operand, `0` = value read in ID, `1` = EX/MEM result,
`2` = MEM/WB write-back value, with **EX/MEM winning** over MEM/WB (the youngest in-flight writer is the architecturally
correct one) and `$0` never forwarded. The same forwarded operands feed the ALU, the branch comparator, the `jr` target
and the store-data path, so control flow needs no extra forwarding hardware.

### Load-use interlock
`hazard_unit` stalls the instruction in ID for one cycle iff the instruction in EX is a load with a non-zero
destination that matches a register the ID instruction **actually consumes** (`uses_rs`, `uses_rt` come from the
decoder, so `lui`, `j`, an I-type's destination field, etc. never cause false stalls). While stalled the PC and IF/ID are
frozen and a bubble enters EX. After one cycle the load sits in MEM/WB and ordinary forwarding takes over —
therefore **a stall never lasts more than one cycle** (assertion A05).

### MEM→MEM store-data forwarding (parameter `MEM_MEM_FWD`)
A store whose *data* register (`rt`) was produced by the immediately preceding load would otherwise stall one cycle.
With `MEM_MEM_FWD=1` it does not: the store reads a stale `rt` in EX, and in the MEM stage — when the load has
reached MEM/WB — `mem_stage` replaces the store data with `memwb_value`. The base register (`rs`) is *not* covered
(an address is needed in EX), so `lw $a0,..; sw $t1,0($a0)` still stalls.

*Why the replacement is always correct.* When a store S is in MEM, MEM/WB holds the instruction immediately
preceding S in program order (bubbles are never reordered). If it writes `S.rt`, it is by definition the youngest
writer of `S.rt`, so its value is the right one; if it does not, no other in-flight instruction can be a younger
writer, and the value captured in EX (forwarded or read from the RF) was already right.
Assertion A11/A12 and the `38_hazard_matrix` test (store-data column) exercise exactly this; the simulator variant
built with `-DNO_MEM_MEM_FWD` stalls instead and must produce the identical architectural result.

### Why a link value can only be forwarded from MEM/WB
The dynamic successor of a `jal` is ≥ 2 slots behind it in the pipeline (the squashed fetch sits in between), and
≥ 3 behind a `jalr`. So a consumer of `$ra`/the link register is never at distance 1 from the linking instruction
(a coverage bin that is provably unreachable was deliberately replaced by `fwd_memwb_of_link`).

## 2. Control hazards

The pipeline predicts **not-taken** and has no delay slot.

| instruction | resolved in | redirect when | slots squashed | cycles lost |
|---|---|---|---:|---:|
| `beq bne blez bgtz bltz bgez` | EX | condition true | 2 (IF/ID, ID/EX) | 2 |
| `jr`, `jalr` | EX | always | 2 | 2 |
| `j`, `jal` | ID | always | 1 (IF/ID) | 1 |
| not-taken branch | – | – | 0 | 0 |

```text
 taken beq (EX at t3)            F D X M W
   wrong path 1                    F D x          <- flushed from ID/EX
   wrong path 2                      F x          <- flushed from IF/ID
   target                              F D X M W
 j (ID at t2)                    F D X M W
   wrong path                      F x            <- flushed from IF/ID
   target                            F D X M W
```

### Arbitration rules
1. `ex_redirect` has priority over the `j/jal` in ID: the jump is itself wrong-path (it sits behind the redirecting
   instruction) and must not redirect (`redirect_id = id_jump & ~ex_redirect & ~stall`; assertion A08b).
2. A load-use stall and an EX redirect can never coincide (the instruction in EX would have to be both a load and a
   branch); the hazard unit still gates defensively (A01).
3. `ex_redirect` ⇒ a **valid** instruction sits in ID (A08d). Proof sketch: IF/ID can only hold a bubble after a flush
   in the previous cycle; a flush is caused either by an older EX redirect (which would have squashed the redirecting
   branch too) or by a `j/jal` in ID (but the instruction behind the branch is in ID, and the branch is not a `j`).
   Consequently *exactly two valid slots* are squashed by every EX redirect, which is what makes the cycle model exact.

### Wrong-path safety
A bubble has `valid=0` **and** every control signal zeroed, so it can never write a register, access memory, redirect
the PC or raise an exception (A14). Flushing therefore only needs to clear `valid`, and wrong-path stores, loads,
`break`s, illegal opcodes, misaligned/out-of-range accesses, `jal` (which would clobber `$ra`) are all
architecturally invisible — see directed test 23 and coverage bins `wrongpath_*`.

## 3. Structural hazards
None: separate instruction/data memories, a register file with two read ports and one write port used by different
stages in the same cycle (write-through handles same-register read-during-write).

## 4. Halting
`wb_stage` raises `halt_now` when an instruction with a non-zero exception code reaches WB. On that cycle `stop`
(= `halted | halt_now`) clears the valid bit of every younger stage and freezes the PC; `mem_stage` also gates the
data-memory write with `~stop`, because the instruction directly behind a halting one is *in MEM* in that very
cycle and would otherwise commit a store.

## 5. The cycle-accounting identity

Every cycle the WB stage either retires an instruction or holds a bubble, and every bubble has exactly one origin:

```text
cycles = instret
       + 4                      pipeline fill (first instruction reaches WB in cycle 5)
       + load-use stalls        one bubble each
       + 2 × (taken conditional branches + jr + jalr)
       + 1 × (j + jal)
       + 1 if the program ended with a non-retiring fault (ILLEGAL/ADDR)
```

This holds for **every** run and is asserted by `tools/regress.py` against the RTL hardware counters. The event
counters in `mips_core` only count events whose source instruction is *older* than any halting instruction in
flight, since bubbles created behind a halting instruction never reach WB.

`tools/perfmodel.py` predicts all of these quantities from the ISS trace alone and additionally implements an
issue-time recurrence (`timeline`) that reproduces the cycle count exactly while also supporting design what-ifs.
