# Microarchitecture

![pipeline](img/pipeline.svg)

## Module hierarchy

```text
mips_core                         rtl/mips_core.v          top level: wiring + performance events
├── if_stage                      rtl/if_stage.v           PC, next-PC mux, IF/ID register
├── regfile                       rtl/regfile.v            32x32, 2R/1W, write-through bypass
├── id_stage                      rtl/id_stage.v           decode, immediate, branch/jump targets, ID/EX register
│   └── decoder                   rtl/decoder.v            instruction -> control signals (shared with single-cycle)
├── hazard_unit                   rtl/hazard_unit.v        load-use interlock, flush/redirect arbitration
├── forwarding_unit               rtl/forwarding_unit.v    EX operand bypass selects
├── ex_stage                      rtl/ex_stage.v           forwarding muxes, ALU, branch/jr resolution, EX/MEM register
│   ├── alu                       rtl/alu.v                (shared)
│   └── branch_cond               rtl/branch_cond.v        (shared)
├── mem_stage                     rtl/mem_stage.v          data-memory access, MEM->MEM store bypass, MEM/WB register
│   ├── mem_check / load_fmt / store_fmt   rtl/mem_utils.v (shared)
└── wb_stage                      rtl/wb_stage.v           commit, halt/exception control, retirement trace

mips_single_cycle                 rtl/mips_single_cycle.v  baseline; same decoder/ALU/regfile/memory helpers
perf_counters                     rtl/perf_counters.v      cycle/event/instruction-mix counters (testbench side)
imem, dmem                        rtl/memories.v           behavioural Harvard memories
```

Everything under `rtl/` is plain **Verilog-2005** (`make lint` elaborates it with `iverilog -g2005 -Wall`,
`` `default_nettype none `` is used in every file, so a mistyped net is an error rather than an implicit wire). The
testbench, assertions and coverage are SystemVerilog.

The five stages are separate modules, each of which **owns the pipeline register at its output**; combinational glue
between stages lives only in `mips_core` and in the two hazard-control units. That keeps each stage independently
readable and makes the pipeline registers' reset/flush/stall behaviour local and auditable.

## Interface (identical for both cores)

| group | signals |
|---|---|
| memories | `imem_addr/data` (combinational read) · `dmem_addr/wdata/be/we/rdata` |
| halt | `halted`, `halt_cause[1:0]`, `halt_pc`, `halt_addr` |
| retirement | `ret_valid ret_pc ret_instr ret_wen ret_waddr ret_wdata ret_mem_op ret_mem_size ret_mem_addr ret_mem_data` |
| events | `evt_stall evt_ex_redirect evt_id_redirect evt_squash[1:0] evt_br evt_br_taken evt_fwd_exmem[1:0] evt_fwd_memwb[1:0]` |

Parameters: `RESET_PC`, `MEM_MEM_FWD` (store-data MEM→MEM forwarding on/off), `DMEM_ADDR_BITS`.

## Stage by stage

### IF — `if_stage`
* `PC` register; `imem_addr = PC`. Next PC, highest priority first: `ex_redirect` → `redirect_id` → hold (stall) →
  `PC+4`.
* IF/ID register: on **flush** it takes a bubble (the instruction fetched this cycle is wrong-path); on **stall** it holds;
  on **stop** (halt) it clears `valid`.

### ID — `id_stage`
* Decodes the instruction (`decoder`), reads the register file, sign/zero-extends the immediate, precomputes the
  branch target `PC+4 + (imm<<2)` and the `j/jal` target `{PC+4[31:28], idx, 2'b00}`.
* Exposes `id_uses_rs / id_uses_rt / id_is_store / id_jump` combinationally to the hazard unit; these are gated with
  `ifid_valid` so a bubble in ID can never cause a stall or a redirect.
* ID/EX loads a **bubble** (valid = 0 *and* every control zero) on reset, flush, stall, stop, or when IF/ID is itself a
  bubble.

### EX — `ex_stage`
* Operand muxes pick, per `fwd_a/fwd_b`, the ID/EX register value, the EX/MEM result or the MEM/WB value.
  ALU operand A is `shamt_sel ? zext(shamt) : rs`; B is `alu_src_imm ? imm : rt` — so immediate and variable shifts use
  one datapath.
* Branch comparison and the `jr` target use the *forwarded* `rs/rt` — there is no separate forwarding path for control flow.
* Result is `is_link ? PC+4 : ALU`. `jr/jalr` to a misaligned address raises `ADDR` and suppresses both the redirect
  and the link write.
* `exmem_rt_val` carries the (forwarded) `rt`, i.e. the store data.

### MEM — `mem_stage`
* `mem_check` flags a misaligned or out-of-range access; a faulting access never reaches memory and the instruction
  is tagged `EXC_ADDR`.
* `store_fmt` replicates the store data into byte lanes and produces byte enables; `load_fmt` extracts and
  sign/zero-extends the addressed byte/half from the aligned word.
* MEM→MEM store-data bypass (see `docs/HAZARDS.md`), `dmem_we` gated by `~fault & ~stop`.
* MEM/WB carries the **final write-back value** for every instruction type, so forwarding from MEM/WB is a single mux
  input.

### WB — `wb_stage`
* The architecturally oldest instruction is here, so this is where state is committed, exceptions are taken and the
  retirement trace is produced. `halt_now` → `stop` kills every younger stage on the same edge.

## Pipeline register contents

| register | carries |
|---|---|
| IF/ID | `valid, pc, instr` |
| ID/EX | `valid, pc, pc+4, instr, rs/rt indices, uses_rs/uses_rt, rs_val, rt_val, imm, shamt, dest, reg_write, alu_op, alu_src_imm, shamt_sel, br_type, is_jr, is_link, br_target, mem_read/write/size/signed, exc` |
| EX/MEM | `valid, pc, instr, result, rt_val, rt, dest, reg_write, mem_read/write/size/signed, exc` |
| MEM/WB | `valid, pc, instr, value, dest, reg_write, exc, bad_addr, mem_op/size/addr/data` (trace) |

`pc`/`instr` are carried only for the retirement trace, assertions and the debug view — they cost flops, not logic.

## Single-cycle baseline
`mips_single_cycle` is built from the same `decoder`, `alu`, `branch_cond`, `regfile`, `mem_check/load_fmt/store_fmt`
modules and has the same ports, so one testbench, one reference model and one regression flow validate both cores. It
retires one instruction per clock; its only structural difference in the shared modules is `regfile #(.BYPASS(0))` —
in a one-cycle design the write data depends combinationally on the read data, so the write-through bypass would
create a (false, but real) combinational loop. (That bug was found on the first multi-program run: the simulator
hung. It is documented in the file header.)

## Performance counters and events
The core exposes one-cycle *event* pulses (stall, EX redirect, ID redirect, squashed slots, conditional branch,
taken branch, forwards by source); `perf_counters` accumulates them together with a retired-instruction mix.
Events are suppressed when their source instruction is younger than a halting instruction in flight (see the identity
in `docs/HAZARDS.md`).

## Parameters and build variants
| variant | build flag | meaning |
|---|---|---|
| `sim_pipe` | – | pipelined, `MEM_MEM_FWD=1` |
| `sim_pipe_nomm` | `-DNO_MEM_MEM_FWD` | pipelined, load→store-data stalls instead |
| `sim_single` | `-DSINGLE_CYCLE` | single-cycle baseline |

## Inspecting the pipeline
`make pipeview T=file.s` (or `python3 tools/pipeview.py file.s`) runs a program on the RTL and prints the stage
occupancy of every instruction — real output of this design:

```text
    pc  instruction                      1    5    10   15   20
000000  lw $t0, 0($zero)             F D X M W . . . . . . . . .
000004  addu $t1, $t0, $t0           . F d D X M W . . . . . . .      <- load-use: held one cycle in ID
000008  addiu $t2, $zero, 1          . . f F D X M W . . . . . .      <- held in IF behind the stall
00000c  beq $t2, $t2, 0x1c           . . . . F D X M W . . . . .      <- taken
000010  addiu $s0, $zero, 1          . . . . . F D x . . . . . .      <- squashed from ID/EX
000014  addiu $s1, $zero, 2          . . . . . . F x . . . . . .      <- squashed from IF/ID
00001c  j 0x24                       . . . . . . . F D X M W . .
000020  addiu $s3, $zero, 4          . . . . . . . . F x . . . .      <- squashed behind the j (1 slot)
000024  addiu $v0, $t1, 1            . . . . . . . . . F D X M W
```
(`F D X M W` = IF ID EX MEM WB, `d`/`f` = held by a stall, `x` = squashed.)
