#!/usr/bin/env python3
"""Mutation testing: does the verification environment actually catch bugs?

Each mutant is a small, realistic RTL bug (a dropped forwarding path, a wrong
priority, a missing flush, an off-by-one in an immediate, ...) applied to a
private copy of rtl/.  The pipelined / no-MEM->MEM / single-cycle simulators are
rebuilt from the mutated copy and the directed + random regression is run
against the *unmodified* ISS.  A mutant is KILLED if any test fails (trace
mismatch, final-state mismatch, assertion failure, perf-model mismatch ...)
and SURVIVES if every test still passes -- a survivor is either an equivalent
mutant or a hole in the test suite and must be investigated.

Usage: mutation.py [--seeds N] [--only SUBSTR] [--list]
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@dataclass
class Mutant:
    name: str
    file: str
    old: str
    new: str
    note: str = ""
    variants: str = "pipe,nomm"


M = Mutant
MUTANTS = [
    # ------------------------------------------------------------ forwarding unit
    M("fwd_drop_exmem_a", "forwarding_unit.v", "wire a_exmem = exmem_we &&", "wire a_exmem = 1'b0 && exmem_we &&", "no EX/MEM->EX on rs"),
    M("fwd_drop_exmem_b", "forwarding_unit.v", "wire b_exmem = exmem_we &&", "wire b_exmem = 1'b0 && exmem_we &&", "no EX/MEM->EX on rt"),
    M("fwd_drop_memwb_a", "forwarding_unit.v", "wire a_memwb = memwb_we &&", "wire a_memwb = 1'b0 && memwb_we &&", "no MEM/WB->EX on rs"),
    M("fwd_drop_memwb_b", "forwarding_unit.v", "wire b_memwb = memwb_we &&", "wire b_memwb = 1'b0 && memwb_we &&", "no MEM/WB->EX on rt"),
    M("fwd_priority_swap", "forwarding_unit.v", "assign fwd_a = a_exmem ? 2'd1 : a_memwb ? 2'd2 : 2'd0;",
      "assign fwd_a = a_memwb ? 2'd2 : a_exmem ? 2'd1 : 2'd0;", "older writer beats younger"),
    M("fwd_zero_exmem", "forwarding_unit.v", "wire a_exmem = exmem_we && (exmem_dest != 5'd0) &&", "wire a_exmem = exmem_we &&", "forwards writes to $0 from EX/MEM"),
    M("fwd_zero_memwb", "forwarding_unit.v", "wire b_memwb = memwb_we && (memwb_dest != 5'd0) &&", "wire b_memwb = memwb_we &&", "forwards writes to $0 from MEM/WB"),
    M("fwd_wrong_operand", "forwarding_unit.v", "(exmem_dest == ex_rs);", "(exmem_dest == ex_rt);", "A-select compares against rt"),
    M("fwd_ignores_valid", "mips_core.v", ".exmem_we(exmem_valid & exmem_reg_write)", ".exmem_we(exmem_reg_write)", "bubble in EX/MEM can forward"),
    # ------------------------------------------------------------------ hazard unit
    M("hz_no_loaduse", "hazard_unit.v", "assign stall       = load_use & ~ex_redirect;", "assign stall       = 1'b0;", "load-use interlock removed"),
    M("hz_ignore_rt", "hazard_unit.v", "wire rt_needed  = id_uses_rt & ~((MEM_MEM_FWD != 0) & id_is_store);", "wire rt_needed  = 1'b0;", "rt dependence ignored"),
    M("hz_ignore_rs", "hazard_unit.v", "(id_uses_rs & (id_rs == ex_dest)) |", "(1'b0 & (id_rs == ex_dest)) |", "rs dependence ignored"),
    M("hz_imprecise", "hazard_unit.v", "(id_uses_rs & (id_rs == ex_dest)) |", "((id_rs == ex_dest)) |", "stalls even if rs unused (perf only)"),
    M("hz_store_rt_excluded_always", "hazard_unit.v", "~((MEM_MEM_FWD != 0) & id_is_store)", "~id_is_store", "store-data exclusion even without MEM->MEM", ),
    M("hz_no_idex_flush", "hazard_unit.v", "assign flush_idex  = ex_redirect;", "assign flush_idex  = 1'b0;", "wrong-path instr in ID reaches EX"),
    M("hz_no_ex_ifid_flush", "hazard_unit.v", "assign flush_ifid  = ex_redirect | redirect_id;", "assign flush_ifid  = redirect_id;", "wrong-path fetch survives EX redirect"),
    M("hz_jump_beats_branch", "hazard_unit.v", "assign redirect_id = id_jump & ~ex_redirect & ~stall;", "assign redirect_id = id_jump & ~stall;", "squashed j still redirects/flushes"),
    M("hz_loaduse_ignores_dest0", "hazard_unit.v", "& ex_reg_write & (ex_dest != 5'd0);", "& ex_reg_write;", "stall on loads to $0 (perf only)"),
    # ---------------------------------------------------------------------- IF stage
    M("if_stall_no_freeze_pc", "if_stage.v", "wire pc_en = redirect_ex | redirect_id | ~stall;", "wire pc_en = 1'b1;", "PC advances during stall"),
    M("if_stall_no_freeze_ifid", "if_stage.v", "end else if (!stall) begin\n                ifid_valid <= 1'b1;", "end else begin\n                ifid_valid <= 1'b1;", "IF/ID overwritten during stall"),
    M("if_flush_keeps_valid", "if_stage.v", "            if (flush) begin\n                ifid_valid <= 1'b0;", "            if (flush) begin\n                ifid_valid <= 1'b1;", "flush does not clear IF/ID"),
    M("if_redirect_priority", "if_stage.v", "wire [31:0] next_pc = redirect_ex ? target_ex :\n                          redirect_id ? target_id :", "wire [31:0] next_pc = redirect_id ? target_id :\n                          redirect_ex ? target_ex :", "ID redirect beats EX redirect"),
    # ---------------------------------------------------------------------- ID stage
    M("id_branch_target", "id_stage.v", "wire [31:0] br_target = pc4 + {imm[29:0], 2'b00};", "wire [31:0] br_target = ifid_pc + {imm[29:0], 2'b00};", "branch offset relative to PC, not PC+4"),
    M("id_jump_target", "id_stage.v", "{pc4[31:28], ifid_instr[25:0], 2'b00}", "{ifid_pc[31:28], ifid_instr[23:0], 4'b0000}", "j target field decoded wrongly"),
    M("id_bubble_keeps_ctrl", "id_stage.v", "wire bubble = rst | stop | flush | stall | ~ifid_valid;", "wire bubble = rst | stop | flush | stall;", "invalid IF/ID decoded as an instruction"),
    # ---------------------------------------------------------------------- EX stage
    M("ex_branch_unforwarded", "ex_stage.v", ".a(op_a), .b(op_b), .taken(br_taken_raw)", ".a(idex_rs_val), .b(idex_rt_val), .taken(br_taken_raw)", "branch compares unforwarded operands"),
    M("ex_store_unforwarded", "ex_stage.v", "exmem_rt_val     <= op_b;", "exmem_rt_val     <= idex_rt_val;", "store data not forwarded"),
    M("ex_jr_unforwarded", "ex_stage.v", "assign ex_target   = idex_is_jr ? op_a : idex_br_target;", "assign ex_target   = idex_is_jr ? idex_rs_val : idex_br_target;", "jr target not forwarded"),
    M("ex_link_pc", "ex_stage.v", "idex_is_link  ? idex_pc4 : alu_y;", "idex_is_link  ? idex_pc : alu_y;", "link address = PC (not PC+4)"),
    M("ex_no_jr_align_check", "ex_stage.v", "wire jr_misaligned = idex_valid & idex_is_jr & (op_a[1:0] != 2'b00);", "wire jr_misaligned = 1'b0;", "misaligned jr accepted"),
    M("ex_alu_b_imm_for_shift", "ex_stage.v", "wire [31:0] alu_a = idex_shamt_sel   ? {27'b0, idex_shamt} : op_a;", "wire [31:0] alu_a = idex_shamt_sel   ? {27'b0, idex_rt} : op_a;", "shamt taken from rt field"),
    M("ex_bubble_not_cleared", "ex_stage.v", "if (rst || stop || !idex_valid) begin", "if (rst || stop) begin", "bubble copied into EX/MEM valid"),
    # --------------------------------------------------------------- ALU / branch / decode
    M("alu_sra_logical", "alu.v", "`ALU_SRA:  y = sb >>> sh;", "`ALU_SRA:  y = b >> sh;", "SRA is logical"),
    M("alu_sltu_signed", "alu.v", "`ALU_SLTU: y = {31'b0, (a < b)};", "`ALU_SLTU: y = {31'b0, (sa < sb)};", "SLTU signed"),
    M("alu_slt_unsigned", "alu.v", "`ALU_SLT:  y = {31'b0, (sa < sb)};", "`ALU_SLT:  y = {31'b0, (a < b)};", "SLT unsigned"),
    M("alu_shamt_4bit", "alu.v", "wire [4:0]         sh = a[4:0];", "wire [4:0]         sh = {1'b0, a[3:0]};", "variable shift uses 4 bits"),
    M("alu_nor", "alu.v", "`ALU_NOR:  y = ~(a | b);", "`ALU_NOR:  y = ~(a & b);", "NOR wrong"),
    M("alu_lui", "alu.v", "`ALU_LUI:  y = {b[15:0], 16'b0};", "`ALU_LUI:  y = {a[15:0], 16'b0};", "LUI shifts wrong operand"),
    M("bc_bgez", "branch_cond.v", "`BR_GEZ: taken = ~a[31];", "`BR_GEZ: taken = ~a[31] & (a != 32'b0);", "BGEZ excludes zero"),
    M("bc_blez", "branch_cond.v", "`BR_LEZ: taken = a[31] | (a == 32'b0);", "`BR_LEZ: taken = a[31];", "BLEZ excludes zero"),
    M("dec_andi_sext", "decoder.v", "alu_src_imm = 1; imm_zext = 1; alu_op = `ALU_AND;", "alu_src_imm = 1; alu_op = `ALU_AND;", "ANDI sign-extends"),
    M("dec_sltiu_as_slti", "decoder.v", "alu_op = `ALU_SLTU; end\n        `OP_ANDI", "alu_op = `ALU_SLT; end\n        `OP_ANDI", "SLTIU decoded as SLTI"),
    M("dec_lh_unsigned", "decoder.v", "mem_size = `SZ_H; mem_signed = 1; end", "mem_size = `SZ_H; end", "LH zero-extends"),
    M("dec_lui_uses_rs", "decoder.v", "`OP_LUI:   begin dest = rt; reg_write = 1; alu_src_imm", "`OP_LUI:   begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm", "LUI marked as reading rs (perf only)"),
    M("dec_store_no_rt", "decoder.v", "`OP_SW:  begin uses_rs = 1; uses_rt = 1;", "`OP_SW:  begin uses_rs = 1;", "SW rt dependence not declared"),
    M("dec_jal_no_link_reg", "decoder.v", "`OP_JAL:  begin is_jump = 1; is_link = 1; dest = 5'd31; reg_write = 1; end", "`OP_JAL:  begin is_jump = 1; is_link = 1; dest = 5'd30; reg_write = 1; end", "JAL writes $30"),
    M("dec_sub_as_add", "decoder.v", "`FN_SUBU: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SUB; end", "`FN_SUBU: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_ADD; end", "SUB(U) adds"),
    # ------------------------------------------------------------------- register file
    M("rf_no_bypass", "regfile.v", "(BYPASS != 0 && we && waddr == raddr1) ? wdata :", "1'b0 ? wdata :", "no write-through on port 1"),
    M("rf_no_bypass2", "regfile.v", "(BYPASS != 0 && we && waddr == raddr2) ? wdata :", "1'b0 ? wdata :", "no write-through on port 2"),
    M("rf_write_r0", "regfile.v", "if (we && waddr != 5'd0) regs[waddr] <= wdata;", "if (we) regs[waddr] <= wdata;", "$0 writable"),
    M("rf_r0_read", "regfile.v", "assign rdata1 = (raddr1 == 5'd0)            ? 32'b0 :", "assign rdata1 = (1'b0)            ? 32'b0 :", "$0 not forced to zero on port 1"),
    # ------------------------------------------------------------------------ memory
    M("mem_byte_lane", "mem_utils.v", "be    = 4'b0001 << byte_off;", "be    = 4'b0001;", "sb always lane 0"),
    M("mem_half_lane", "mem_utils.v", "be    = byte_off[1] ? 4'b1100 : 4'b0011;", "be    = 4'b0011;", "sh always low half"),
    M("mem_lb_sign", "mem_utils.v", "`SZ_B:   value = sign_ext ? {{24{b[7]}},  b} : {24'b0, b};", "`SZ_B:   value = sign_ext ? {{24{b[6]}},  b} : {24'b0, b};", "lb sign bit"),
    M("mem_lh_lane", "mem_utils.v", "h = byte_off[1] ? word[31:16] : word[15:0];", "h = word[15:0];", "lh ignores address bit 1"),
    M("mem_no_half_align", "mem_utils.v", "(size == `SZ_H && addr[0]   != 1'b0);", "1'b0;", "misaligned halfword accepted"),
    M("mem_no_range", "mem_utils.v", "wire out_of_range = |(addr >> ADDR_BITS);", "wire out_of_range = 1'b0;", "range check removed"),
    M("mem_store_on_fault", "mem_stage.v", "assign dmem_we   = exmem_valid & exmem_mem_write & ~fault_c & ~stop;", "assign dmem_we   = exmem_valid & exmem_mem_write & ~stop;", "faulting store still writes"),
    M("mem_store_after_halt", "mem_stage.v", "assign dmem_we   = exmem_valid & exmem_mem_write & ~fault_c & ~stop;", "assign dmem_we   = exmem_valid & exmem_mem_write & ~fault_c;", "younger store commits during halt"),
    M("mem_stfwd_dest0", "mem_stage.v", "(memwb_dest != 5'd0) & (memwb_dest == exmem_rt);", "(memwb_dest == exmem_rt);", "MEM->MEM fwd of $0"),
    M("mem_stfwd_wrong_reg", "mem_stage.v", "(memwb_dest != 5'd0) & (memwb_dest == exmem_rt);", "(memwb_dest != 5'd0) & (memwb_dest == exmem_dest);", "MEM->MEM compares dest"),
    M("mem_stfwd_off", "mem_stage.v", "assign st_fwd = (MEM_MEM_FWD != 0) &", "assign st_fwd = 1'b0 & (MEM_MEM_FWD != 0) &", "MEM->MEM forwarding broken (stalls suppressed)"),
    M("mem_load_wb_value", "mem_stage.v", "memwb_value     <= exmem_mem_read ? load_val : exmem_result;", "memwb_value     <= exmem_result;", "load data not written back"),
    M("mem_fault_regwrite", "mem_stage.v", "memwb_reg_write <= exmem_reg_write & ~mem_fault;", "memwb_reg_write <= exmem_reg_write;", "faulting load result visible to forwarding"),
    # -------------------------------------------------------------------------- WB
    M("wb_break_no_retire", "wb_stage.v", "wire commit = live & ((memwb_exc == `EXC_NONE) | (memwb_exc == `EXC_BREAK));", "wire commit = live & (memwb_exc == `EXC_NONE);", "break not retired"),
    M("wb_illegal_retires", "wb_stage.v", "wire commit = live & ((memwb_exc == `EXC_NONE) | (memwb_exc == `EXC_BREAK));", "wire commit = live & (memwb_exc != `EXC_ADDR);", "illegal instruction retires"),
    M("wb_no_stop", "wb_stage.v", "assign stop     = halted | halt_now;", "assign stop     = halted;", "younger instructions not squashed on halt"),
    M("wb_wrong_pc", "wb_stage.v", "halt_pc    <= memwb_pc;", "halt_pc    <= memwb_pc + 32'd4;", "EPC off by one"),
    # ---------------------------------------------------------------- single-cycle
    M("sc_branch_target", "mips_single_cycle.v", "wire [31:0] branch_target = pc4 + {imm[29:0], 2'b00};", "wire [31:0] branch_target = pc + {imm[29:0], 2'b00};", "single-cycle branch offset", "single"),
    M("sc_link", "mips_single_cycle.v", "assign rf_wdata = is_link ? pc4 : mem_read ? load_val : alu_y;", "assign rf_wdata = is_link ? pc : mem_read ? load_val : alu_y;", "single-cycle link", "single"),
    M("sc_store_fault", "mips_single_cycle.v", "assign dmem_we   = live & mem_write & (exc == `EXC_NONE);", "assign dmem_we   = live & mem_write;", "single-cycle faulting store writes", "single"),
]


def apply(m: Mutant, dst: Path) -> None:
    f = dst / "rtl" / m.file
    text = f.read_text()
    n = text.count(m.old)
    if n != 1:
        raise RuntimeError(f"mutant {m.name}: pattern occurs {n} times in {m.file}")
    f.write_text(text.replace(m.old, m.new))


def build(m: Mutant, d: Path) -> bool:
    rtl = sorted((d / "rtl").glob("*.v"))
    tb = [ROOT / "tb" / n for n in ("tb_mips.sv", "mips_assertions.sv", "mips_coverage.sv")]
    flags = ["-g2012", "-Wno-timescale", "-I", str(d / "rtl"), "-I", str(ROOT / "tb"), "-s", "tb_mips"]
    cmds = [("sim_pipe.vvp", [], tb), ("sim_pipe_nomm.vvp", ["-DNO_MEM_MEM_FWD"], tb),
            ("sim_single.vvp", ["-DSINGLE_CYCLE"], tb[:1])]
    for out, extra, srcs in cmds:
        r = subprocess.run(["iverilog", *flags, *extra, "-o", str(d / out), *map(str, rtl), *map(str, srcs)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[-400:])
            return False
    return True


def write_report(rows, nk, n, seeds):
    L = ["# Mutation-testing report\n",
         "_Generated by `tools/mutation.py` (`make mutation`)._\n",
         f"**{nk}/{n} mutants killed.** Each row is a single realistic RTL bug injected into a private copy of `rtl/`; "
         f"the pipelined, no-MEM→MEM and single-cycle simulators are rebuilt and the full directed + {seeds}-seed random "
         "regression is run against the unmodified ISS. *Detected by* is the first failure reported.\n",
         "| mutant | file | injected bug | result | first detection |", "|---|---|---|---|---|"]
    for m, res, ev in rows:
        ev = ev.replace("|", "/")
        L.append(f"| `{m.name}` | `{m.file}` | {m.note} | {res} | {ev[:90]} |")
    (ROOT / "docs" / "MUTATION.md").write_text("\n".join(L) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=60)
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    muts = [m for m in MUTANTS if args.only in m.name]
    if args.list:
        for m in muts:
            print(f"{m.name:<30} {m.file:<22} {m.note}")
        return 0

    base = ROOT / "build" / "mutants"
    shutil.rmtree(base, ignore_errors=True)
    t0 = time.time()
    survivors, killed = [], []
    rows = []
    print(f"{'mutant':<32}{'result':<10}{'detected by'}")
    print("-" * 100)
    for m in muts:
        d = base / m.name
        (d / "rtl").parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / "rtl", d / "rtl")
        try:
            apply(m, d)
        except RuntimeError as e:
            print(f"{m.name:<32}ERROR     {e}")
            return 2
        if not build(m, d):
            print(f"{m.name:<32}BUILD-ERR")
            survivors.append(m)
            continue
        env = dict(os.environ, MIPS_SIM_DIR=str(d), MIPS_WORK=str(d / "work"))
        r = subprocess.run([sys.executable, str(ROOT / "tools" / "regress.py"), "all", "--seeds", str(args.seeds),
                            "--quiet", "--variants", m.variants], capture_output=True, text=True, env=env)
        if r.returncode == 0:
            survivors.append(m)
            rows.append((m, "**SURVIVED**", ""))
            print(f"{m.name:<32}SURVIVED  ({m.note})")
        else:
            killed.append(m)
            # first failure line as evidence
            ev = ""
            for line in r.stdout.splitlines():
                if line.strip().startswith("!"):
                    ev = line.strip()[2:].strip()
                    break
            rows.append((m, "killed", ev))
            print(f"{m.name:<32}killed    {ev[:62]}")
        shutil.rmtree(d, ignore_errors=True)
    print("-" * 100)
    print(f"{len(killed)}/{len(muts)} mutants killed ({100.0*len(killed)/max(1,len(muts)):.1f}%), "
          f"{len(survivors)} survived, {time.time()-t0:.0f}s")
    for m in survivors:
        print(f"  SURVIVOR: {m.name} -- {m.note}")
    if not args.only:
        write_report(rows, len(killed), len(muts), args.seeds)
    return 0 if not survivors else 1


if __name__ == "__main__":
    sys.exit(main())
