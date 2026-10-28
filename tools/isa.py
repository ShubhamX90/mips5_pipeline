"""MIPS-5 ISA definition: single source of truth for the assembler, the
instruction-set simulator, the disassembler and the random program generator.

Encodings mirror rtl/mips_defs.vh.  Everything here is deliberately plain
data + small pure functions so that the ISS shares *no code* with the RTL.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

MASK32 = 0xFFFFFFFF

REG_NAMES = [
    "zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
    "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
    "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra",
]
REG_NUM: Dict[str, int] = {n: i for i, n in enumerate(REG_NAMES)}
REG_NUM["s8"] = 30

# ---- exception / halt causes (mirror EXC_* in mips_defs.vh) -----------------
EXC_NONE, EXC_BREAK, EXC_ILLEGAL, EXC_ADDR = 0, 1, 2, 3
EXC_NAMES = {0: "none", 1: "break", 2: "illegal", 3: "addr"}

# ---- memory map -------------------------------------------------------------
IMEM_WORDS = 4096          # 16 KiB, address 0
DMEM_WORDS = 4096          # 16 KiB, address 0 (separate address space)
IMEM_BYTES = IMEM_WORDS * 4
DMEM_BYTES = DMEM_WORDS * 4
ILLEGAL_FETCH = 0xFFFFFFFF


@dataclass(frozen=True)
class Op:
    name: str
    fmt: str            # operand format, see assembler
    opcode: int
    funct: Optional[int] = None   # SPECIAL/SPECIAL2 funct
    rt_fixed: Optional[int] = None  # REGIMM


# fmt codes:
#  rd_rs_rt   : op rd, rs, rt
#  rd_rt_sh   : op rd, rt, shamt
#  rd_rt_rs   : op rd, rt, rs   (variable shifts)
#  rs         : op rs                      (jr)
#  rd_rs      : op rd, rs                  (jalr; rd optional -> $ra)
#  rt_rs_imm  : op rt, rs, imm
#  rt_imm     : op rt, imm                 (lui)
#  rt_mem     : op rt, off(rs)
#  rs_rt_lbl  : op rs, rt, label
#  rs_lbl     : op rs, label
#  lbl        : op label
#  none       : op
OPS = [
    # SPECIAL (opcode 0)
    Op("sll",  "rd_rt_sh",  0x00, 0x00), Op("srl",  "rd_rt_sh",  0x00, 0x02),
    Op("sra",  "rd_rt_sh",  0x00, 0x03), Op("sllv", "rd_rt_rs",  0x00, 0x04),
    Op("srlv", "rd_rt_rs",  0x00, 0x06), Op("srav", "rd_rt_rs",  0x00, 0x07),
    Op("jr",   "rs",        0x00, 0x08), Op("jalr", "rd_rs",     0x00, 0x09),
    Op("break", "none",     0x00, 0x0D),
    Op("add",  "rd_rs_rt",  0x00, 0x20), Op("addu", "rd_rs_rt",  0x00, 0x21),
    Op("sub",  "rd_rs_rt",  0x00, 0x22), Op("subu", "rd_rs_rt",  0x00, 0x23),
    Op("and",  "rd_rs_rt",  0x00, 0x24), Op("or",   "rd_rs_rt",  0x00, 0x25),
    Op("xor",  "rd_rs_rt",  0x00, 0x26), Op("nor",  "rd_rs_rt",  0x00, 0x27),
    Op("slt",  "rd_rs_rt",  0x00, 0x2A), Op("sltu", "rd_rs_rt",  0x00, 0x2B),
    # SPECIAL2
    Op("mul",  "rd_rs_rt",  0x1C, 0x02),
    # REGIMM
    Op("bltz", "rs_lbl",    0x01, rt_fixed=0), Op("bgez", "rs_lbl", 0x01, rt_fixed=1),
    # J-type
    Op("j",    "lbl",       0x02), Op("jal",  "lbl",       0x03),
    # branches
    Op("beq",  "rs_rt_lbl", 0x04), Op("bne",  "rs_rt_lbl", 0x05),
    Op("blez", "rs_lbl",    0x06), Op("bgtz", "rs_lbl",    0x07),
    # I-type ALU
    Op("addi", "rt_rs_imm", 0x08), Op("addiu", "rt_rs_imm", 0x09),
    Op("slti", "rt_rs_imm", 0x0A), Op("sltiu", "rt_rs_imm", 0x0B),
    Op("andi", "rt_rs_imm", 0x0C), Op("ori",   "rt_rs_imm", 0x0D),
    Op("xori", "rt_rs_imm", 0x0E), Op("lui",   "rt_imm",    0x0F),
    # loads / stores
    Op("lb",  "rt_mem", 0x20), Op("lh",  "rt_mem", 0x21), Op("lw", "rt_mem", 0x23),
    Op("lbu", "rt_mem", 0x24), Op("lhu", "rt_mem", 0x25),
    Op("sb",  "rt_mem", 0x28), Op("sh",  "rt_mem", 0x29), Op("sw", "rt_mem", 0x2B),
]
OP_BY_NAME: Dict[str, Op] = {o.name: o for o in OPS}

_SPECIAL = {o.funct: o for o in OPS if o.opcode == 0x00}
_SPECIAL2 = {o.funct: o for o in OPS if o.opcode == 0x1C}
_REGIMM = {o.rt_fixed: o for o in OPS if o.opcode == 0x01}
_PRIMARY = {o.opcode: o for o in OPS if o.opcode not in (0x00, 0x01, 0x1C)}


def sext(value: int, bits: int) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def s32(v: int) -> int:
    return sext(v, 32)


# ---- encoding -----------------------------------------------------------------
def enc_r(opcode, rs, rt, rd, shamt, funct):
    return ((opcode & 0x3F) << 26) | ((rs & 31) << 21) | ((rt & 31) << 16) | \
           ((rd & 31) << 11) | ((shamt & 31) << 6) | (funct & 0x3F)


def enc_i(opcode, rs, rt, imm):
    return ((opcode & 0x3F) << 26) | ((rs & 31) << 21) | ((rt & 31) << 16) | (imm & 0xFFFF)


def enc_j(opcode, target_word_index):
    return ((opcode & 0x3F) << 26) | (target_word_index & 0x3FFFFFF)


# ---- decoding -----------------------------------------------------------------
def lookup(instr: int) -> Optional[Op]:
    """Return the Op for an instruction word, or None if it is illegal."""
    opcode = instr >> 26
    funct = instr & 0x3F
    if opcode == 0x00:
        return _SPECIAL.get(funct)
    if opcode == 0x1C:
        return _SPECIAL2.get(funct)
    if opcode == 0x01:
        return _REGIMM.get((instr >> 16) & 31)
    return _PRIMARY.get(opcode)


def fields(instr: int):
    return {
        "opcode": instr >> 26,
        "rs": (instr >> 21) & 31,
        "rt": (instr >> 16) & 31,
        "rd": (instr >> 11) & 31,
        "shamt": (instr >> 6) & 31,
        "funct": instr & 0x3F,
        "imm": instr & 0xFFFF,
        "target": instr & 0x3FFFFFF,
    }


def rn(i: int) -> str:
    return "$" + REG_NAMES[i]


def disasm(instr: int, pc: int = 0) -> str:
    op = lookup(instr)
    if op is None:
        return f".illegal 0x{instr:08x}"
    f = fields(instr)
    n, fmt = op.name, op.fmt
    simm = sext(f["imm"], 16)
    if instr == 0:
        return "nop"
    if fmt == "rd_rs_rt":
        return f"{n} {rn(f['rd'])}, {rn(f['rs'])}, {rn(f['rt'])}"
    if fmt == "rd_rt_sh":
        return f"{n} {rn(f['rd'])}, {rn(f['rt'])}, {f['shamt']}"
    if fmt == "rd_rt_rs":
        return f"{n} {rn(f['rd'])}, {rn(f['rt'])}, {rn(f['rs'])}"
    if fmt == "rs":
        return f"{n} {rn(f['rs'])}"
    if fmt == "rd_rs":
        return f"{n} {rn(f['rd'])}, {rn(f['rs'])}"
    if fmt == "rt_rs_imm":
        imm = f["imm"] if n in ("andi", "ori", "xori") else simm
        return f"{n} {rn(f['rt'])}, {rn(f['rs'])}, {imm}"
    if fmt == "rt_imm":
        return f"{n} {rn(f['rt'])}, 0x{f['imm']:x}"
    if fmt == "rt_mem":
        return f"{n} {rn(f['rt'])}, {simm}({rn(f['rs'])})"
    if fmt == "rs_rt_lbl":
        return f"{n} {rn(f['rs'])}, {rn(f['rt'])}, 0x{(pc + 4 + (simm << 2)) & MASK32:x}"
    if fmt == "rs_lbl":
        return f"{n} {rn(f['rs'])}, 0x{(pc + 4 + (simm << 2)) & MASK32:x}"
    if fmt == "lbl":
        return f"{n} 0x{(((pc + 4) & 0xF0000000) | (f['target'] << 2)) & MASK32:x}"
    return n


# ---- instruction classification (used by the performance model / generators) --
LOADS = {"lb", "lh", "lw", "lbu", "lhu"}
STORES = {"sb", "sh", "sw"}
COND_BRANCHES = {"beq", "bne", "blez", "bgtz", "bltz", "bgez"}


@dataclass(frozen=True)
class Usage:
    name: str
    uses_rs: bool
    uses_rt: bool
    dest: int            # 0 if none
    is_load: bool
    is_store: bool
    is_cond_branch: bool
    is_jr: bool
    is_direct_jump: bool


def usage(instr: int) -> Optional[Usage]:
    """Architectural register read/write sets of an instruction (None if illegal)."""
    op = lookup(instr)
    if op is None:
        return None
    f = fields(instr)
    fmt, n = op.fmt, op.name
    rs = rt = False
    dest = 0
    if fmt in ("rd_rs_rt", "rd_rt_rs"):
        rs, rt, dest = True, True, f["rd"]
    elif fmt == "rd_rt_sh":
        rt, dest = True, f["rd"]
    elif fmt == "rs":
        rs = True
    elif fmt == "rd_rs":
        rs, dest = True, f["rd"]
    elif fmt == "rt_rs_imm":
        rs, dest = True, f["rt"]
    elif fmt == "rt_imm":
        dest = f["rt"]
    elif fmt == "rt_mem":
        rs = True
        if n in LOADS:
            dest = f["rt"]
        else:
            rt = True
    elif fmt == "rs_rt_lbl":
        rs = rt = True
    elif fmt == "rs_lbl":
        rs = True
    if n == "jal":
        dest = 31
    return Usage(n, rs, rt, dest, n in LOADS, n in STORES, n in COND_BRANCHES,
                 n in ("jr", "jalr"), n in ("j", "jal"))
