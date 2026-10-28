# Instruction-set architecture

The core implements a deliberately small, cleanly-specified subset of **MIPS32** (big-picture: the integer
instruction set a textbook five-stage pipeline needs), plus a handful of explicit, documented deviations that
keep the microarchitecture honest and the reference model simple. `tools/isa.py` and `rtl/mips_defs.vh` are the
two machine-readable copies of this specification; `tools/iss.py` implements the semantics below from scratch.

## Programmer-visible state

| item | definition |
|---|---|
| registers | 32 × 32-bit, `$0` hard-wired to zero. Reset value: all zero |
| PC | 32-bit, word aligned, reset vector `0x0000_0000` |
| instruction memory | 16 KiB, **separate address space** (Harvard), mapped at `0x0000_0000`–`0x0000_3FFF` |
| data memory | 16 KiB, separate address space, mapped at `0x0000_0000`–`0x0000_3FFF`, **little-endian** |
| size parameters | `IMEM_WORDS`, `DMEM_WORDS` (default 4096 each) in `tb_mips`; `DMEM_ADDR_BITS` on the cores |

## Instructions (44)

All encodings are the standard MIPS32 encodings.

| class | instructions |
|---|---|
| R-type ALU | `add addu sub subu and or xor nor slt sltu` |
| shifts | `sll srl sra` (shamt) · `sllv srlv srav` (low 5 bits of `rs`) |
| multiply | `mul rd,rs,rt` (SPECIAL2, `rd = low32(rs*rt)`, one EX cycle) |
| I-type ALU | `addi addiu slti sltiu` (sign-extended imm) · `andi ori xori` (zero-extended imm) · `lui` |
| loads | `lb lbu lh lhu lw` |
| stores | `sb sh sw` |
| branches | `beq bne blez bgtz bltz bgez` |
| jumps | `j jal jr jalr` |
| system | `break` (halts the core) |

`sltiu` sign-extends its immediate and then compares *unsigned*, exactly as MIPS32 specifies.
`nop` is `sll $0,$0,0` (`0x00000000`).

## Deliberate deviations from MIPS32

| deviation | rationale |
|---|---|
| **No branch/jump delay slot.** The instruction after a taken branch or jump is *not* executed. | Keeps the programmer model simple and makes "branch flush" a first-class pipeline mechanism (as in Harris & Harris). |
| **Link address is `PC+4`** (not `PC+8`) for `jal`/`jalr`. | Direct consequence of having no delay slot. `jr $ra` returns to the instruction after the call. |
| **No overflow traps.** `add`, `sub`, `addi` behave exactly like `addu`, `subu`, `addiu`. | The core has no CP0/exception-vector machinery. |
| **No HI/LO, `mult`, `div`.** `mul` (SPECIAL2) returns the low word directly. | A 32×32→32 multiply is the only multi-cycle-class operation the benchmarks need. It is modelled as a single-cycle EX op (see `docs/BENCHMARKS.md` for the timing-model caveat). |
| **Reserved/should-be-zero fields are ignored** (e.g. `shamt` in `add`, `rt` in `blez`). | Common implementation practice; ISS does the same. |
| **`syscall`, `bltzal`, `bgezal`, `clz`, unaligned loads/stores, ll/sc, coprocessors** are *not implemented* → illegal instruction. | Out of scope. |

## Memory system

* Instruction and data memories are independent (Harvard). Both have **combinational read**; data memory has a
  **synchronous, byte-enabled write**.
* Alignment: `lw/sw` need `addr[1:0]==0`, `lh/lhu/sh` need `addr[0]==0`; `lb/lbu/sb` any address.
* **Address faults.** An access that is misaligned *or* outside `[0, 16 KiB)` does not touch memory and halts the core
  with cause `ADDR` (the faulting instruction does not retire).
* **Fetch from unmapped instruction memory** (including never-loaded locations) yields the all-ones word
  `0xFFFFFFFF` (primary opcode `0x3F`, undefined) → `ILLEGAL` if it reaches write-back. Wrong-path fetches beyond the
  image are therefore harmless, but a program that runs off its end is *detected*.
* `jr`/`jalr` to a non-word-aligned address raises `ADDR` on the jump instruction itself; no redirect happens and no
  link register is written.

## Halt / exception model

There are no exception vectors. Instead the core has **four halt causes**, reported precisely at the in-order
commit point (write-back):

| cause | code | trigger | retires? |
|---|---:|---|---|
| none | 0 | still running | – |
| `BREAK` | 1 | `break` instruction | **yes** (it appears in the retirement trace) |
| `ILLEGAL` | 2 | undefined encoding or unmapped fetch | no |
| `ADDR` | 3 | misaligned/out-of-range load, store, or `jr`/`jalr` target | no |

*Precision* guarantee: when the core halts, every older instruction has fully committed and **no younger instruction
has had any architectural effect** (no register write, no memory write). This is checked by directed tests 25–37, by
2 of the assertions (A15, A19) and by the random generator (one program in 16 ends in an injected fault).

## Retirement trace and state-dump formats

Both the ISS and the RTL testbench emit the same text formats so they can be compared byte for byte.

```text
# one line per retired instruction, program order
PC INSTR RD WDATA MOP MSIZE MADDR MDATA
00000010 8c0a0004 10 0000002a 1 2 00000004 0000002a      <- lw $t2,4($zero)
```

| field | meaning |
|---|---|
| `PC`, `INSTR` | 8 hex digits |
| `RD` | 2-digit decimal destination register actually written (`00` if none, including writes to `$0`) |
| `WDATA` | value written (0 if none) |
| `MOP` | 0 none · 1 load · 2 store |
| `MSIZE` | log2(bytes) (0 when `MOP=0`) |
| `MADDR` | effective address (0 when `MOP=0`) |
| `MDATA` | loaded value after extension, or stored value right-justified and masked to the access size |

```text
HALT <cause> <pc> <bad-address>     RET <retired>     REG nn hhhhhhhh (x32)     MEM addr word (non-zero words)
```

## Assembler (`tools/asm.py`)

Two-pass, produces `$readmemh` images for both memories. Besides the 44 instructions it supports:

* pseudo-ops `nop move li la b beqz bnez blt ble bgt bge not neg` (`blt`-family use `$at`);
* directives `.text .data .word .half .byte .space .ascii .asciiz .align .org .equ .inst`;
* **test macros** `check $r, imm, id`, `checkr $a, $b, id`, `.endtest` — the self-checking idiom used by the directed
  tests: on mismatch the program stores the failing check id in `$k1`, sets `$k0=0x0BAD` and halts; on success
  `$k0=0x600D`.

Register conventions used by the test programs: `$at` and `$k0/$k1` are reserved for the harness macros; `$gp`
(`$28`) is the data-window base in random programs; `$sp` is initialised by the program (e.g. `0x3F00`).
