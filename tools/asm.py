#!/usr/bin/env python3
"""Two-pass assembler for the MIPS-5 ISA.

Produces a Harvard image pair:
    <out>.imem.hex   one 32-bit word per line ($readmemh format), address 0
    <out>.dmem.hex   likewise for the .data segment, address 0 of data memory
    <out>.sym.json   label -> address
    <out>.lst        address / word / source listing

Directives : .text .data .word .half .byte .space .ascii .asciiz .align .org .inst
             .equ NAME, expr   .globl (ignored)   .endtest
             .inst WORD[,..]  emit raw instruction word(s) in .text (for illegal-opcode tests)
Pseudo-ops : nop move li la b beqz bnez blt ble bgt bge not neg check
Registers  : $0..$31, $zero $at $v0.. $ra, $s8
Expressions: integers (dec/hex/bin), labels, .equ names, + - * << >> | & ( )

Self-checking test support
    check $reg, expected, id
        expands to:  li $at,expected ; ori $k1,$0,id ; bne $reg,$at,__fail
    .endtest
        emits  __pass: ori $k0,$0,0x600D ; break
               __fail: ori $k0,$0,0x0BAD ; break
        ($k1 holds the id of the first failed check.)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isa  # noqa: E402

PASS_CODE = 0x600D
FAIL_CODE = 0x0BAD


class AsmError(Exception):
    pass


@dataclass
class Program:
    imem: List[int] = field(default_factory=list)       # words
    dmem: bytearray = field(default_factory=bytearray)  # bytes
    symbols: Dict[str, int] = field(default_factory=dict)
    listing: List[Tuple[int, int, str]] = field(default_factory=list)

    def dmem_words(self) -> List[int]:
        d = bytes(self.dmem) + b"\0" * ((-len(self.dmem)) % 4)
        return [int.from_bytes(d[i:i + 4], "little") for i in range(0, len(d), 4)]


_REG_RE = re.compile(r"^\$(\w+)$")


def parse_reg(tok: str) -> int:
    m = _REG_RE.match(tok.strip())
    if not m:
        raise AsmError(f"bad register '{tok}'")
    name = m.group(1)
    if name.isdigit():
        n = int(name)
        if 0 <= n < 32:
            return n
    elif name in isa.REG_NUM:
        return isa.REG_NUM[name]
    raise AsmError(f"unknown register '{tok}'")


def split_operands(s: str) -> List[str]:
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


_SAFE_EXPR = re.compile(r"^[0-9a-fA-FxXbB_+\-*()<>|&~ \t]*$")
_IDENT = re.compile(r"[A-Za-z_.][A-Za-z_0-9.]*")


class Assembler:
    def __init__(self) -> None:
        self.symbols: Dict[str, int] = {}
        self.equs: Dict[str, int] = {}

    # ---- expression evaluation ---------------------------------------------------
    def eval(self, expr: str, allow_forward: bool, lineno: int) -> int:
        expr = expr.strip()
        if expr.startswith("'") and expr.endswith("'") and len(expr) == 3:
            return ord(expr[1])

        def sub(m):
            name = m.group(0)
            if name in self.equs:
                return str(self.equs[name])
            if name in self.symbols:
                return str(self.symbols[name])
            if allow_forward:
                return "0"
            raise AsmError(f"line {lineno}: undefined symbol '{name}'")

        # identifiers that are not hex literals (0x..) -- only substitute names
        pieces = re.split(r"(0[xX][0-9a-fA-F_]+|0[bB][01_]+|\b\d+\b)", expr)
        rebuilt = []
        for p in pieces:
            if re.fullmatch(r"0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d+", p or ""):
                rebuilt.append(p)
            else:
                rebuilt.append(_IDENT.sub(sub, p))
        e = "".join(rebuilt)
        if not _SAFE_EXPR.match(e):
            raise AsmError(f"line {lineno}: bad expression '{expr}'")
        try:
            return int(eval(e, {"__builtins__": {}}, {}))  # noqa: S307 (sanitised above)
        except Exception as ex:  # noqa: BLE001
            raise AsmError(f"line {lineno}: cannot evaluate '{expr}': {ex}")

    def const(self, expr: str, lineno: int) -> int:
        """Expression that must be resolvable *now* (no forward labels)."""
        return self.eval(expr, False, lineno)

    # ---- driver ---------------------------------------------------------------------
    def assemble(self, text: str) -> Program:
        lines = self._preprocess(text)
        self._pass(lines, final=False)
        prog = self._pass(lines, final=True)
        prog.symbols = dict(self.symbols)
        return prog

    @staticmethod
    def _preprocess(text: str):
        out = []
        for i, raw in enumerate(text.splitlines(), 1):
            line = raw
            # strip comments (outside of quotes)
            in_q = False
            for j, ch in enumerate(line):
                if ch == '"':
                    in_q = not in_q
                elif ch == "#" and not in_q:
                    line = line[:j]
                    break
            line = line.strip()
            if line:
                out.append((i, raw.rstrip(), line))
        return out

    # ---- size of a (pseudo-)instruction in words -----------------------------------
    def _li_words(self, val: int) -> int:
        v = val & isa.MASK32
        sv = isa.s32(v)
        if -32768 <= sv <= 32767 or 0 <= v <= 0xFFFF:
            return 1
        return 2

    def _size(self, mnem: str, ops: List[str], lineno: int) -> int:
        if mnem in ("nop", "move", "b", "beqz", "bnez", "not", "neg"):
            return 1
        if mnem == "li":
            return self._li_words(self.const(ops[1], lineno))
        if mnem == "la":
            return 2
        if mnem in ("blt", "ble", "bgt", "bge"):
            return 2
        if mnem == "check":
            return self._li_words(self.const(ops[1], lineno)) + 2
        if mnem == ".endtest":
            return 4
        return 1

    # ---- one pass ---------------------------------------------------------------------
    def _pass(self, lines, final: bool) -> Program:
        prog = Program()
        section = "text"
        pc = 0            # text byte address
        dp = 0            # data byte address
        if not final:
            self.symbols = {}

        def emit_word(w: int, src: str, lineno: int):
            nonlocal pc
            if final:
                prog.imem.append(w & isa.MASK32)
                prog.listing.append((pc, w & isa.MASK32, src))
            pc += 4
            if pc > isa.IMEM_BYTES:
                raise AsmError(f"line {lineno}: text segment exceeds {isa.IMEM_BYTES} bytes")

        def emit_data(b: bytes, lineno: int):
            nonlocal dp
            if final:
                prog.dmem.extend(b)
            dp += len(b)
            if dp > isa.DMEM_BYTES:
                raise AsmError(f"line {lineno}: data segment exceeds {isa.DMEM_BYTES} bytes")

        for lineno, raw, line in lines:
            # labels (possibly several, possibly followed by a statement)
            while True:
                m = re.match(r"^([A-Za-z_.][A-Za-z_0-9.]*)\s*:\s*(.*)$", line)
                if not m:
                    break
                label, line = m.group(1), m.group(2).strip()
                addr = pc if section == "text" else dp
                if not final:
                    if label in self.symbols or label in self.equs:
                        raise AsmError(f"line {lineno}: duplicate label '{label}'")
                    self.symbols[label] = addr
            if not line:
                continue

            parts = line.split(None, 1)
            mnem = parts[0].lower()
            rest = parts[1] if len(parts) > 1 else ""

            # ---- directives
            if mnem.startswith("."):
                if mnem == ".text":
                    section = "text"
                elif mnem == ".data":
                    section = "data"
                elif mnem == ".globl":
                    pass
                elif mnem == ".equ":
                    ops = split_operands(rest)
                    if len(ops) != 2:
                        raise AsmError(f"line {lineno}: .equ NAME, value")
                    if not final:
                        self.equs[ops[0]] = self.const(ops[1], lineno)
                elif mnem == ".org":
                    target = self.const(rest, lineno)
                    if section == "text":
                        if target < pc:
                            raise AsmError(f"line {lineno}: .org moves backwards")
                        while pc < target:
                            emit_word(isa.ILLEGAL_FETCH, ".org fill", lineno)
                    else:
                        if target < dp:
                            raise AsmError(f"line {lineno}: .org moves backwards")
                        emit_data(b"\0" * (target - dp), lineno)
                elif mnem == ".align":
                    n = self.const(rest, lineno)
                    a = 1 << n
                    if section == "data":
                        emit_data(b"\0" * ((-dp) % a), lineno)
                    else:
                        while pc % a:
                            emit_word(isa.ILLEGAL_FETCH, ".align fill", lineno)
                elif mnem in (".word", ".half", ".byte"):
                    if section != "data":
                        raise AsmError(f"line {lineno}: {mnem} only allowed in .data")
                    size = {".word": 4, ".half": 2, ".byte": 1}[mnem]
                    if dp % size and final:
                        raise AsmError(f"line {lineno}: {mnem} at unaligned data address {dp:#x}")
                    for e in split_operands(rest):
                        v = self.eval(e, not final, lineno)
                        emit_data((v & ((1 << (8 * size)) - 1)).to_bytes(size, "little"), lineno)
                elif mnem == ".space":
                    if section != "data":
                        raise AsmError(f"line {lineno}: .space only allowed in .data")
                    emit_data(b"\0" * self.const(rest, lineno), lineno)
                elif mnem in (".ascii", ".asciiz"):
                    m2 = re.match(r'^"(.*)"$', rest.strip())
                    if not m2:
                        raise AsmError(f"line {lineno}: {mnem} needs a quoted string")
                    s = bytes(m2.group(1), "utf-8").decode("unicode_escape").encode("latin-1")
                    emit_data(s + (b"\0" if mnem == ".asciiz" else b""), lineno)
                elif mnem == ".inst":
                    if section != "text":
                        raise AsmError(f"line {lineno}: .inst only allowed in .text")
                    for e in split_operands(rest):
                        emit_word(self.eval(e, not final, lineno), f".inst {e}", lineno)
                elif mnem == ".endtest":
                    if section != "text":
                        raise AsmError(f"line {lineno}: .endtest only in .text")
                    if not final:
                        for lab, off in (("__pass", 0), ("__fail", 8)):
                            if lab in self.symbols:
                                raise AsmError(f"line {lineno}: duplicate {lab}")
                            self.symbols[lab] = pc + off
                    emit_word(isa.enc_i(0x0D, 0, 26, PASS_CODE), "__pass: ori $k0,$0,0x600D", lineno)
                    emit_word(isa.enc_r(0, 0, 0, 0, 0, 0x0D), "        break", lineno)
                    emit_word(isa.enc_i(0x0D, 0, 26, FAIL_CODE), "__fail: ori $k0,$0,0x0BAD", lineno)
                    emit_word(isa.enc_r(0, 0, 0, 0, 0, 0x0D), "        break", lineno)
                else:
                    raise AsmError(f"line {lineno}: unknown directive {mnem}")
                continue

            if section != "text":
                raise AsmError(f"line {lineno}: instruction in .data section")

            ops = split_operands(rest)
            try:
                self._emit_instr(mnem, ops, lineno, line, pc, final, emit_word)
            except AsmError:
                raise
            except Exception as ex:  # noqa: BLE001
                raise AsmError(f"line {lineno}: {ex} in '{line}'")
        return prog

    # ---- instruction emission ------------------------------------------------------------
    def _imm16(self, expr: str, lineno: int, signed: bool, final: bool) -> int:
        v = self.eval(expr, not final, lineno)
        if not final:
            return 0
        if signed:
            if not -32768 <= v <= 32767:
                raise AsmError(f"line {lineno}: immediate {v} out of signed 16-bit range")
        else:
            if not 0 <= v <= 0xFFFF:
                raise AsmError(f"line {lineno}: immediate {v} out of unsigned 16-bit range")
        return v & 0xFFFF

    def _branch_off(self, label: str, pc: int, lineno: int, final: bool) -> int:
        target = self.eval(label, not final, lineno)
        if not final:
            return 0
        if target % 4:
            raise AsmError(f"line {lineno}: unaligned branch target")
        off = (target - (pc + 4)) // 4
        if not -32768 <= off <= 32767:
            raise AsmError(f"line {lineno}: branch out of range")
        return off & 0xFFFF

    def _emit_instr(self, mnem, ops, lineno, src, pc, final, emit):
        E = lambda w: emit(w, src, lineno)  # noqa: E731
        need = lambda n: self._need(mnem, ops, n, lineno)  # noqa: E731
        R = parse_reg

        # ----- pseudo-instructions
        if mnem == "nop":
            need(0); return E(0)
        if mnem == "move":
            need(2); return E(isa.enc_r(0, R(ops[1]), 0, R(ops[0]), 0, 0x21))  # addu rd,rs,$0
        if mnem == "not":
            need(2); return E(isa.enc_r(0, R(ops[1]), 0, R(ops[0]), 0, 0x27))  # nor rd,rs,$0
        if mnem == "neg":
            need(2); return E(isa.enc_r(0, 0, R(ops[1]), R(ops[0]), 0, 0x23))  # subu rd,$0,rs
        if mnem == "li":
            need(2); return self._emit_li(R(ops[0]), self.const(ops[1], lineno), E)
        if mnem == "la":
            need(2)
            v = self.eval(ops[1], not final, lineno) & isa.MASK32
            rt = R(ops[0])
            E(isa.enc_i(0x0F, 0, rt, v >> 16))
            return E(isa.enc_i(0x0D, rt, rt, v & 0xFFFF))
        if mnem == "b":
            need(1); return E(isa.enc_i(0x04, 0, 0, self._branch_off(ops[0], pc, lineno, final)))
        if mnem in ("beqz", "bnez"):
            need(2)
            return E(isa.enc_i(0x04 if mnem == "beqz" else 0x05, R(ops[0]), 0,
                               self._branch_off(ops[1], pc, lineno, final)))
        if mnem in ("blt", "ble", "bgt", "bge"):
            need(3)
            rs, rt = R(ops[0]), R(ops[1])
            # blt: slt at,rs,rt ; bne at,0     bge: slt at,rs,rt ; beq at,0
            # bgt: slt at,rt,rs ; bne at,0     ble: slt at,rt,rs ; beq at,0
            a, b = (rs, rt) if mnem in ("blt", "bge") else (rt, rs)
            E(isa.enc_r(0, a, b, 1, 0, 0x2A))
            br = 0x05 if mnem in ("blt", "bgt") else 0x04
            return E(isa.enc_i(br, 1, 0, self._branch_off(ops[2], pc + 4, lineno, final)))
        if mnem == "check":
            need(3)
            rA = R(ops[0])
            expected = self.const(ops[1], lineno)
            cid = self.const(ops[2], lineno)
            self._emit_li(1, expected, E)
            E(isa.enc_i(0x0D, 0, 27, cid))
            fail = self.eval("__fail", not final, lineno)
            cur = pc + 4 * (self._li_words(expected) + 1)
            off = ((fail - (cur + 4)) // 4) & 0xFFFF if final else 0
            return E(isa.enc_i(0x05, rA, 1, off))

        # ----- real instructions
        op = isa.OP_BY_NAME.get(mnem)
        if op is None:
            raise AsmError(f"line {lineno}: unknown instruction '{mnem}'")
        fmt = op.fmt
        if fmt == "rd_rs_rt":
            need(3); return E(isa.enc_r(op.opcode, R(ops[1]), R(ops[2]), R(ops[0]), 0, op.funct))
        if fmt == "rd_rt_sh":
            need(3)
            sh = self.const(ops[2], lineno)
            if not 0 <= sh < 32:
                raise AsmError(f"line {lineno}: shift amount {sh} out of range")
            return E(isa.enc_r(0, 0, R(ops[1]), R(ops[0]), sh, op.funct))
        if fmt == "rd_rt_rs":
            need(3); return E(isa.enc_r(0, R(ops[2]), R(ops[1]), R(ops[0]), 0, op.funct))
        if fmt == "rs":
            need(1); return E(isa.enc_r(0, R(ops[0]), 0, 0, 0, op.funct))
        if fmt == "rd_rs":
            if len(ops) == 1:
                ops = ["$ra", ops[0]]
            need(2); return E(isa.enc_r(0, R(ops[1]), 0, R(ops[0]), 0, op.funct))
        if fmt == "rt_rs_imm":
            need(3)
            signed = mnem not in ("andi", "ori", "xori")
            return E(isa.enc_i(op.opcode, R(ops[1]), R(ops[0]), self._imm16(ops[2], lineno, signed, final)))
        if fmt == "rt_imm":
            need(2); return E(isa.enc_i(op.opcode, 0, R(ops[0]), self._imm16(ops[1], lineno, False, final)))
        if fmt == "rt_mem":
            need(2)
            m = re.match(r"^(.*)\((\$\w+)\)$", ops[1].strip())
            if m:
                off_expr, base = (m.group(1).strip() or "0"), R(m.group(2))
            else:  # "label" alone => absolute via $zero
                off_expr, base = ops[1], 0
            return E(isa.enc_i(op.opcode, base, R(ops[0]), self._imm16(off_expr, lineno, True, final)))
        if fmt == "rs_rt_lbl":
            need(3)
            return E(isa.enc_i(op.opcode, R(ops[0]), R(ops[1]), self._branch_off(ops[2], pc, lineno, final)))
        if fmt == "rs_lbl":
            need(2)
            rt = op.rt_fixed if op.rt_fixed is not None else 0
            return E(isa.enc_i(op.opcode, R(ops[0]), rt, self._branch_off(ops[1], pc, lineno, final)))
        if fmt == "lbl":
            need(1)
            target = self.eval(ops[0], not final, lineno)
            if final and target % 4:
                raise AsmError(f"line {lineno}: unaligned jump target")
            return E(isa.enc_j(op.opcode, (target >> 2) & 0x3FFFFFF))
        if fmt == "none":
            need(0); return E(isa.enc_r(0, 0, 0, 0, 0, op.funct))
        raise AsmError(f"line {lineno}: internal: unhandled format {fmt}")

    def _emit_li(self, rt: int, val: int, E):
        v = val & isa.MASK32
        sv = isa.s32(v)
        if -32768 <= sv <= 32767:
            return E(isa.enc_i(0x09, 0, rt, sv & 0xFFFF))      # addiu rt,$0,sv
        if 0 <= v <= 0xFFFF:
            return E(isa.enc_i(0x0D, 0, rt, v))                # ori rt,$0,v
        E(isa.enc_i(0x0F, 0, rt, v >> 16))                     # lui
        return E(isa.enc_i(0x0D, rt, rt, v & 0xFFFF))          # ori

    @staticmethod
    def _need(mnem, ops, n, lineno):
        if len(ops) != n:
            raise AsmError(f"line {lineno}: '{mnem}' expects {n} operand(s), got {len(ops)}")


def assemble(text: str) -> Program:
    return Assembler().assemble(text)


def assemble_file(path) -> Program:
    return assemble(Path(path).read_text())


def write_outputs(prog: Program, prefix: Path) -> None:
    prefix.parent.mkdir(parents=True, exist_ok=True)
    Path(f"{prefix}.imem.hex").write_text("".join(f"{w:08x}\n" for w in prog.imem))
    dw = prog.dmem_words()
    Path(f"{prefix}.dmem.hex").write_text("".join(f"{w:08x}\n" for w in dw) if dw else "00000000\n")
    Path(f"{prefix}.sym.json").write_text(json.dumps(prog.symbols, indent=1, sort_keys=True))
    with open(f"{prefix}.lst", "w") as f:
        for addr, word, src in prog.listing:
            f.write(f"{addr:08x}  {word:08x}  {isa.disasm(word, addr):<32} | {src.strip()}\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("-o", "--out", required=True, help="output prefix")
    args = ap.parse_args(argv)
    try:
        prog = assemble_file(args.source)
    except AsmError as e:
        print(f"{args.source}: error: {e}", file=sys.stderr)
        return 1
    write_outputs(prog, Path(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
