#!/usr/bin/env python3
"""Instruction-set simulator: the software golden reference model.

It is deliberately written from the ISA description (docs/ISA.md) with no code
shared with the RTL.  It emits exactly the same *retirement trace* and *final
state dump* formats as the testbench so the two can be diffed byte for byte.

Trace line (one per retired instruction, program order):
    PC INSTR RD WDATA MOP MSIZE MADDR MDATA
      PC, INSTR  : 8 hex digits
      RD         : 2-digit decimal destination register, 00 if nothing written
      WDATA      : 8 hex digits written to RD (0 if none)
      MOP        : 0 none / 1 load / 2 store
      MSIZE      : log2(bytes) of the access (0 when MOP=0)
      MADDR      : effective address            (0 when MOP=0)
      MDATA      : loaded value (extended) or stored value (right-justified)

State dump:
    HALT <cause 0-3> <pc hex> <bad-address hex>
    RET  <instructions retired>
    REG  <nn> <value hex>        x32
    MEM  <byte-address hex> <word hex>   for every non-zero data-memory word
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isa  # noqa: E402

M = isa.MASK32


@dataclass
class Retired:
    pc: int
    instr: int
    taken: bool = False          # for control-flow instructions: redirected the PC


@dataclass
class Result:
    trace: List[str] = field(default_factory=list)
    retired: List[Retired] = field(default_factory=list)
    regs: List[int] = field(default_factory=lambda: [0] * 32)
    dmem: bytearray = field(default_factory=lambda: bytearray(isa.DMEM_BYTES))
    cause: int = isa.EXC_NONE      # 0 => still running (step limit hit)
    halt_pc: int = 0
    halt_addr: int = 0
    timed_out: bool = False

    @property
    def instret(self) -> int:
        return len(self.retired)

    def state_dump(self) -> str:
        out = [f"HALT {self.cause} {self.halt_pc:08x} {self.halt_addr:08x}",
               f"RET {self.instret}"]
        out += [f"REG {i:02d} {v:08x}" for i, v in enumerate(self.regs)]
        for a in range(0, isa.DMEM_BYTES, 4):
            w = int.from_bytes(self.dmem[a:a + 4], "little")
            if w:
                out.append(f"MEM {a:08x} {w:08x}")
        return "\n".join(out) + "\n"


def load_hex(path) -> List[int]:
    words = []
    for line in Path(path).read_text().split():
        words.append(int(line, 16))
    return words


def run(imem_words: List[int], dmem_words: Optional[List[int]] = None,
        max_steps: int = 2_000_000, reset_pc: int = 0) -> Result:
    res = Result()
    regs = res.regs
    dmem = res.dmem
    for i, w in enumerate(dmem_words or []):
        dmem[i * 4:i * 4 + 4] = (w & M).to_bytes(4, "little")
    imem = list(imem_words) + [isa.ILLEGAL_FETCH] * (isa.IMEM_WORDS - len(imem_words))
    pc = reset_pc

    def halt(cause, at_pc, addr=0):
        res.cause, res.halt_pc, res.halt_addr = cause, at_pc, addr

    for _ in range(max_steps):
        instr = imem[pc >> 2] if 0 <= pc < isa.IMEM_BYTES else isa.ILLEGAL_FETCH
        op = isa.lookup(instr)
        if op is None:
            halt(isa.EXC_ILLEGAL, pc)
            return res

        f = isa.fields(instr)
        rs, rt, rd, sh = f["rs"], f["rt"], f["rd"], f["shamt"]
        a, b = regs[rs], regs[rt]
        simm = isa.sext(f["imm"], 16)
        uimm = f["imm"]
        n = op.name
        pc4 = (pc + 4) & M
        next_pc = pc4
        wr_reg, wr_val = 0, 0
        mop = msize = maddr = mdata = 0
        taken = False

        def setreg(r, v):
            nonlocal wr_reg, wr_val
            wr_reg, wr_val = (r, v & M) if r != 0 else (0, 0)

        if n in ("add", "addu"):    setreg(rd, a + b)
        elif n in ("sub", "subu"):  setreg(rd, a - b)
        elif n == "and":            setreg(rd, a & b)
        elif n == "or":             setreg(rd, a | b)
        elif n == "xor":            setreg(rd, a ^ b)
        elif n == "nor":            setreg(rd, ~(a | b))
        elif n == "slt":            setreg(rd, int(isa.s32(a) < isa.s32(b)))
        elif n == "sltu":           setreg(rd, int(a < b))
        elif n == "sll":            setreg(rd, b << sh)
        elif n == "srl":            setreg(rd, b >> sh)
        elif n == "sra":            setreg(rd, isa.s32(b) >> sh)
        elif n == "sllv":           setreg(rd, b << (a & 31))
        elif n == "srlv":           setreg(rd, b >> (a & 31))
        elif n == "srav":           setreg(rd, isa.s32(b) >> (a & 31))
        elif n == "mul":            setreg(rd, a * b)
        elif n in ("addi", "addiu"): setreg(rt, a + simm)
        elif n == "slti":           setreg(rt, int(isa.s32(a) < simm))
        elif n == "sltiu":          setreg(rt, int(a < (simm & M)))
        elif n == "andi":           setreg(rt, a & uimm)
        elif n == "ori":            setreg(rt, a | uimm)
        elif n == "xori":           setreg(rt, a ^ uimm)
        elif n == "lui":            setreg(rt, uimm << 16)
        elif n in ("beq", "bne", "blez", "bgtz", "bltz", "bgez"):
            cond = {"beq": a == b, "bne": a != b,
                    "blez": isa.s32(a) <= 0, "bgtz": isa.s32(a) > 0,
                    "bltz": isa.s32(a) < 0, "bgez": isa.s32(a) >= 0}[n]
            if cond:
                next_pc = (pc4 + (simm << 2)) & M
                taken = True
        elif n == "j":
            next_pc = (pc4 & 0xF0000000) | (f["target"] << 2)
            taken = True
        elif n == "jal":
            next_pc = (pc4 & 0xF0000000) | (f["target"] << 2)
            setreg(31, pc4)
            taken = True
        elif n in ("jr", "jalr"):
            if a & 3:
                halt(isa.EXC_ADDR, pc, a)
                return res
            next_pc = a
            taken = True
            if n == "jalr":
                setreg(rd, pc4)
        elif n in ("lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw"):
            size = {"b": 0, "h": 1, "w": 2}[n[1]]
            nbytes = 1 << size
            addr = (a + simm) & M
            if addr % nbytes or addr + nbytes > isa.DMEM_BYTES:
                halt(isa.EXC_ADDR, pc, addr)
                return res
            mop, msize, maddr = (1 if n[0] == "l" else 2), size, addr
            if n[0] == "l":
                v = int.from_bytes(dmem[addr:addr + nbytes], "little")
                if n in ("lb", "lh"):
                    v = isa.sext(v, 8 * nbytes) & M
                mdata = v
                setreg(rt, v)
            else:
                v = b & ((1 << (8 * nbytes)) - 1)
                dmem[addr:addr + nbytes] = v.to_bytes(nbytes, "little")
                mdata = v
        elif n == "break":
            pass
        else:  # pragma: no cover
            raise RuntimeError(f"ISS: unhandled op {n}")

        if wr_reg:
            regs[wr_reg] = wr_val
        res.trace.append(f"{pc:08x} {instr:08x} {wr_reg:02d} {wr_val:08x} {mop} {msize} {maddr:08x} {mdata:08x}")
        res.retired.append(Retired(pc, instr, taken))
        if n == "break":
            halt(isa.EXC_BREAK, pc)
            return res
        pc = next_pc
    res.timed_out = True
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MIPS-5 instruction-set simulator")
    ap.add_argument("imem")
    ap.add_argument("dmem", nargs="?")
    ap.add_argument("--trace")
    ap.add_argument("--state")
    ap.add_argument("--max-steps", type=int, default=2_000_000)
    args = ap.parse_args(argv)
    res = run(load_hex(args.imem), load_hex(args.dmem) if args.dmem else None, args.max_steps)
    if args.trace:
        Path(args.trace).write_text("".join(t + "\n" for t in res.trace))
    if args.state:
        Path(args.state).write_text(res.state_dump())
    print(f"ISS: {isa.EXC_NAMES.get(res.cause, '?')} after {res.instret} instructions"
          f"{' (TIMEOUT)' if res.timed_out else ''}")
    return 0 if not res.timed_out else 2


if __name__ == "__main__":
    sys.exit(main())
