# Verification

The goal of the verification environment is not "the tests pass" but **"a bug anywhere in the pipeline control would
make something fail"** — and that claim is itself tested (see *Mutation testing*).

## Strategy at a glance

```text
                   ┌─────────────────────────────┐
 tests/asm/*.s ───►│ tools/asm.py (assembler)    │──► imem/dmem images
 tools/randgen.py ─►└─────────────────────────────┘          │
 bench/*.s                                                     ├──────────────┬───────────────────────┐
                                                               ▼              ▼                       ▼
                                                  tools/iss.py          RTL pipeline         RTL single-cycle
                                                  (golden model)     (+ no-MEM→MEM build)         baseline
                                                       │                  │   ▲                     │
                                                       │ retirement trace │   │ SVA assertions      │
                                                       │ + final state    │   │ + coverage          │
                                                       ▼                  ▼   │                     ▼
                                            ┌──────────────────────────────────────────────────────────┐
                                            │ tools/regress.py : byte-exact trace & state comparison,   │
                                            │ cycle-exact perf-model comparison, accounting identity,   │
                                            │ self-check oracle, assertion count, coverage closure      │
                                            └──────────────────────────────────────────────────────────┘
```

Five independent layers, each able to catch bugs the others cannot:

| layer | what it is | what it uniquely catches |
|---|---|---|
| 1. **Golden model** | `tools/iss.py`, written from the ISA spec, no code shared with the RTL | any functional divergence: wrong value, wrong PC, wrong memory effect, wrong halt cause |
| 2. **Lock-step retirement trace** | every retired instruction (PC, instruction, register write, memory op, address, data) compared **byte for byte**; final registers + all of data memory + halt cause/PC/address compared too | wrong-path instructions retiring, missing/extra retirements, wrong order, stray stores |
| 3. **Independent oracles** | self-checking programs (`check`/`checkr` against constants computed with plain Python integer arithmetic), native-Python benchmark results, `zlib.crc32` | bugs shared by the ISS and the RTL (e.g. a misread spec) |
| 4. **Assertions + coverage** | `tb/mips_assertions.sv`, `tb/mips_coverage.sv` | *latent* hazard bugs that don't change this program's result, protocol violations, unreachable-by-accident corners |
| 5. **Timing oracles** | cycle-exact analytical model + hardware cycle-accounting identity | hazard bugs that are functionally masked but cost/lose cycles (spurious or missing stalls, wrong flush counts) |

## 1. The reference model (software)

`tools/iss.py` is a ~200-line instruction-set simulator. It emits exactly the retirement-trace and state-dump formats
documented in `docs/ISA.md`, so comparison is `diff`. It halts with the same four causes and the same precision
guarantee as the RTL. `tools/isa.py` holds the encodings, a disassembler and an architectural register-usage table
that the performance model and the random generator also use.

## 2. Directed tests — 41 programs (`tests/asm/`)

Every test is self-checking (`check` macros, constants computed independently) **and** is compared lock-step with the
ISS on all three RTL variants.

| # | test | what it targets |
|---|---|---|
| 00 | `smoke` | one instruction of every class |
| 01 | `alu_basic` | all R-type ALU ops × 10 boundary operand pairs (100 checks) |
| 02 | `alu_imm` | sign- vs zero-extended immediates, `slti/sltiu` edge cases, `lui` (350 checks) |
| 03 | `shifts` | immediate and variable shifts, amounts 0/31/≥32, arithmetic shift of negatives (234 checks) |
| 04 | `mul` | low-32 multiply, signed/unsigned corners, MUL→MUL forwarding |
| 05 | `raw_forward_exmem` | distance-1 RAW: EX/MEM→EX on rs, rt, both; operand order with `subu` |
| 06 | `raw_forward_memwb` | distance-2 RAW: MEM/WB→EX |
| 07 | `regfile_bypass` | distance-3 (write-through) and distance-4 |
| 08 | `fwd_priority` | several in-flight writers of one register: youngest wins; xor-swap; counters |
| 09 | `fwd_both_operands` | rs and rt forwarded from *different* stages in the same cycle; store with forwarded base and data |
| 10 | `r0_hazard` | writes to `$0` never forward / never stick, at distances 1–3, `lw $0`, `mul $0`, `jal` |
| 11 | `load_use_basic` | load-use on rs / rt / both / shift / I-type; **negative cases** (dest field coincidence must not stall) |
| 12 | `load_use_consumers` | load → branch (rs, rt), `jr`, `jalr`, store base, store data, load base, `mul` |
| 13 | `load_store_interplay` | `lw→sw` data (MEM→MEM), base==data, sub-word stores of loaded values |
| 14 | `load_chain` | pointer chasing; loaded pointer feeding a branch |
| 15 | `load_gap` | load data consumed after 1 and 2 instructions; stale older loads must not leak |
| 16 | `mem_subword` | `lb/lbu/lh/lhu` at every alignment, `sb/sh` merging into words (20 checks) |
| 17 | `store_load_order` | store→load same address back-to-back, partial overlaps, load-before-store |
| 18 | `branch_matrix` | 6 branch types × boundary operands × forward/backward (88 cells), wrong-path marker + store |
| 19 | `branch_operand_sources` | branch operands from `slt`, `mul`, shifts, loads |
| 20 | `loops` | nested loops, down-counters, array loops with load-use, data-dependent exits |
| 21 | `jumps` | `j/jal/jr`, link = PC+4, nested calls on a stack, `$ra` consumed by the callee's first instruction |
| 22 | `indirect_jumps` | jump table via `lw→jr`, `jalr` default/explicit link, `jalr $t,$t` |
| 23 | `wrongpath_effects` | stores (incl. misaligned/out-of-range), loads, **`break`**, **illegal opcodes**, `jal`, register writes in every squashed slot of branch/j/jr/jalr shadows |
| 24 | `back_to_back_control` | branch at a branch target; **taken branch immediately followed by `j` (EX must beat ID)**; `jal` in a taken branch's shadow; ten chained branches; alternating pattern |
| 25–30 | `illegal_*`, `fall_off_end`, `jump_unmapped` | halts with ILLEGAL: undefined opcode/funct/REGIMM/SPECIAL2, running off the image, jumping to unmapped memory — and nothing younger commits |
| 31–35 | `addr_error_*` | misaligned `lw/sw/sh`, out-of-range `sb/lb`, misaligned `jr/jalr`; suppressed writes; no link write |
| 36 | `halt_kills_younger` | stores directly behind a retiring `break` must not reach memory |
| 37 | `halt_after_load_use` | a faulting instruction that is itself stalled by a load-use hazard |
| 38 | `hazard_matrix` | **{ALU, LOAD} producer × distance 0–4 × 10 consumer kinds = 100 cells**, each self-checking |
| 39 | `recursion` | recursive factorial/Fibonacci with a software stack |
| 40 | `decode_precision` | reserved register fields equal to a load's destination must not trigger the interlock |

`tests/gen/*.py` generate the large tests (01–04, 16, 18, 38); the generated `.s` files are committed.

## 3. Constrained-random testing

`tools/randgen.py` produces terminating programs biased toward dense dependencies (small random register pool,
strong preference for recently written sources, loads followed by consumers, loaded pointers used as addresses and
as jump targets, writes to `$0`, forward branches with live shadows, bounded loops, leaf calls, `jalr`). One program in
16 ends in an injected fault so precise halting is tested behind random hazard traffic.
`make random RANDOM_SEEDS=N` — every failure prints a one-line reproducer
(`python3 tools/regress.py one build/random_src/rand_00042.s`).

## 4. SystemVerilog assertions (`tb/mips_assertions.sv`)

Written as clocked immediate assertions (`assert (...) else ...`), which run on any SV-2012 simulator that supports
immediate assertions (Icarus Verilog 12 here). They restate the pipeline **contract** independently of how
`hazard_unit` / `forwarding_unit` compute it:

| id | property |
|---|---|
| A01 | a load-use stall never coincides with an EX redirect |
| A02 | `stall \|=>` bubble in EX, PC frozen, IF/ID frozen |
| A03/A04 | the stall is **sound** (a true RAW dependence on the load in EX exists) and **complete** (every such dependence stalls), for rs and rt |
| A05 | no two stalls back to back |
| A06 | `ex_redirect \|=>` IF/ID and ID/EX are bubbles and fetch is at the registered target |
| A07 | `redirect_id \|=>` IF/ID is a bubble and fetch is at the jump target |
| A08 | redirects come only from valid instructions; EX wins over ID; **a valid instruction always sits in ID behind a redirecting EX instruction** (the invariant behind the 2-slot penalty) |
| A09/A10 | forward-select encoding legal, and equal to *youngest matching in-flight writer wins* |
| A11 | a load's address (EX/MEM result) is never forwarded as data (store data exempt when MEM→MEM repair is on) |
| A12 | MEM→MEM repair only for stores and only when enabled |
| A13 | `$0` is always zero |
| A14 | bubbles are inert in EX, MEM and WB |
| A15 | `dmem_we` only from a valid, un-faulted store while not stopping |
| A16 | byte enables legal |
| A17/A18 | only the WB instruction retires; retired PCs aligned and **sequential unless the previous retiree was a control-flow instruction** (independent of the ISS) |
| A19 | nothing retires or writes memory after halt; `halted` is sticky |
| A20 | no X/Z on control or retirement signals |

(`assert property` / SVA sequences are not used: Icarus 12 does not support concurrent assertions, and immediate
assertions sampled on the clock edge are the portable common subset.)

## 5. Functional coverage (`tb/mips_coverage.sv`)

Hand-rolled cover points (simulator-independent) over every forwarding path per operand, forwarding priority,
register-file bypass, each flavour of load-use (rs, rt, both, for branch, `jr`, load/store base, store data),
each redirect source, EX-vs-ID redirect conflict, wrong-path instructions of every dangerous kind being squashed,
`$0` non-forwarding, and each halt cause. The regression merges the counters and **fails on any coverage hole**
(bins that are architecturally unreachable in a configuration — e.g. `stall_for_store_data` when MEM→MEM forwarding
is on — are required in the other build instead).

Two bins were removed because the analysis showed them *unreachable by construction* — and each became an
assertion instead: `ex_redirect_ifid_bubble` (→ A08d) and EX/MEM forwarding of a link value (→ see
`docs/HAZARDS.md`).

## 6. Cycle-level cross-checks

* **Hardware counters vs. analytical model.** `tools/perfmodel.py` predicts cycles, load-use stalls, EX/ID redirects,
  squashed slots and branch statistics from the ISS trace alone; the regression requires equality with the RTL
  counters for every program on both pipelined builds, and the single-cycle build to equal `instret`.
* **Timeline model.** An independent issue-time recurrence must reproduce the same cycle count.
* **Accounting identity** (`docs/HAZARDS.md §5`): `cycles = instret + 4 + stalls + squashed (+1 on a non-retiring fault)`.

These checks catch hazard-logic bugs that leave results unchanged — e.g. an interlock that fires one cycle too often.

## 7. Mutation testing (`make mutation`, `docs/MUTATION.md`)

71 realistic RTL bugs are injected one at a time into a private copy of `rtl/` — dropped forwarding paths, swapped
priorities, missing flushes, wrong immediates, ALU/decoder slips, byte-lane errors, dropped faults, an unfrozen PC, a
wrong EPC, … The three simulators are rebuilt and the whole directed + random regression is run against the unmodified
ISS. Result: **MUT_RESULT**. The mutation run found one real *hole* — an imprecise interlock (stall on a matching but
unread register field) survived until `40_decode_precision` was written to kill it.

## 8. Running

```bash
make                    # lint, build 3 simulators, directed + 200 random + benchmarks
make test               # directed tests only
make random RANDOM_SEEDS=1000
make mutation           # ~10 minutes
python3 tools/regress.py one tests/asm/24_back_to_back_control.s
make wave T=tests/asm/24_back_to_back_control.s   # VCD in build/wave/wave.vcd
make pipeview T=tests/asm/24_back_to_back_control.s
```

## 9. Honest limitations

* Simulation-based only: no formal proof (the assertions are written so that a tool such as SymbiYosys could take them
  over, but none is installed here) and no synthesis/timing closure — the clock-period numbers in
  `docs/BENCHMARKS.md` are a clearly-labelled analytical model.
* The multiplier is modelled as a single-cycle EX operation; a real 32×32 multiplier would be multi-cycle or would
  set the clock.
* Memories are behavioural with combinational read (textbook model); a registered-read SRAM would add a stage.
* Only one simulator (Icarus Verilog 12) was available; the RTL is kept to strict Verilog-2005 to ease porting.
