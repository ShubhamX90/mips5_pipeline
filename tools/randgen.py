#!/usr/bin/env python3
"""Constrained-random MIPS-5 program generator.

Programs are *guaranteed to terminate* and (unless a fault is injected on
purpose) to stay architecturally legal:

  * all control flow is forward, except bounded counted loops built around a
    reserved counter register;
  * memory accesses are confined to a 256-byte window addressed through $gp (or
    through pointers loaded from / computed against it), with natural alignment;
  * calls go to leaf functions emitted after the main stream; indirect jumps use
    pointers that are always valid code labels.

The generator is biased toward *dense dependencies* -- a small random register
pool, a strong preference for recently-written sources, loads followed by their
consumers, loaded pointers used as addresses and jump targets, writes to $0 --
because that is where pipeline bugs live.  About 1 in 16 programs ends in a
deliberate fault (illegal opcode, misaligned or out-of-range access) so that
precise halting is exercised behind random hazard traffic.

Register roles:   $gp window base | $fp pointer scratch | $s7 loop counter |
                  $t9 jump scratch | $ra link | $at/$k0/$k1 reserved for the harness
Usage: randgen.py SEED [LENGTH]   (prints the program)
"""
from __future__ import annotations

import random
import sys

POOL_ALL = ["$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8",
            "$s0", "$s1", "$s2", "$s3", "$s4", "$s5", "$s6",
            "$a0", "$a1", "$a2", "$a3", "$v0", "$v1"]
WIN_BASE = 0x800
WIN_WORDS = 64
PTR_SLOTS = 8            # words 0..7 of the window hold pointers into words 8..40
JT_BASE = 0x7C0          # jump-target table (separate from the store window)
JT_SLOTS = 16

SIMM = [0, 1, -1, 2, 3, 4, 7, 8, 15, 16, 31, 100, -100, 255, 0x7FFF, -0x8000, 0x1234, -0x1234]
UIMM = [0, 1, 2, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x00F0, 0x0F0F, 0xAAAA]
WORDS = [0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 2, 3, 0xFF, 0xFF00, 0x00FF00FF, 0xDEADBEEF, 0x12345678]


class Gen:
    def __init__(self, seed: int, length: int):
        self.r = random.Random(seed)
        self.target = length
        self.pool = self.r.sample(POOL_ALL, self.r.choice([3, 4, 5, 6, 8, 12]))
        self.recent: list = []
        self.lines: list = []
        self.nlabels = 0
        self.count = 0
        self.nfuncs = self.r.randint(1, 3)
        self.jt: list = []           # label names held in the jump-target table
        self.ptr_targets = [self.r.randint(8, 40) for _ in range(PTR_SLOTS)]
        self.words = [self.rand_word() for _ in range(WIN_WORDS)]
        self.uses_funcs = False

    # ------------------------------------------------------------------ helpers
    def rand_word(self) -> int:
        r = self.r
        k = r.random()
        if k < 0.35:
            return r.choice(WORDS)
        if k < 0.6:
            return r.randint(0, 0xFFFF)
        return r.getrandbits(32)

    def label(self, prefix="L") -> str:
        self.nlabels += 1
        return f"{prefix}{self.nlabels}"

    def emit(self, s: str, n: int = 1):
        self.lines.append("    " + s)
        self.count += n

    def place(self, label: str):
        self.lines.append(f"{label}:")

    def dest(self) -> str:
        if self.r.random() < 0.04:
            return "$zero"
        d = self.r.choice(self.pool)
        self.recent.append(d)
        self.recent = self.recent[-3:]
        return d

    def src(self) -> str:
        k = self.r.random()
        if k < 0.55 and self.recent:
            return self.r.choice(self.recent)
        if k < 0.60:
            return "$zero"
        return self.r.choice(self.pool)

    # ----------------------------------------------------------- instruction kinds
    def alu_rr(self):
        op = self.r.choice(["addu", "subu", "and", "or", "xor", "nor", "slt", "sltu", "add", "sub"])
        self.emit(f"{op} {self.dest()}, {self.src()}, {self.src()}")

    def alu_imm(self):
        k = self.r.random()
        if k < 0.55:
            op = self.r.choice(["addiu", "addi", "slti", "sltiu"])
            self.emit(f"{op} {self.dest()}, {self.src()}, {self.r.choice(SIMM)}")
        else:
            op = self.r.choice(["andi", "ori", "xori"])
            self.emit(f"{op} {self.dest()}, {self.src()}, {self.r.choice(UIMM)}")

    def shift(self):
        if self.r.random() < 0.6:
            op = self.r.choice(["sll", "srl", "sra"])
            self.emit(f"{op} {self.dest()}, {self.src()}, {self.r.choice([0, 1, 2, 4, 8, 16, 31, self.r.randint(0, 31)])}")
        else:
            op = self.r.choice(["sllv", "srlv", "srav"])
            self.emit(f"{op} {self.dest()}, {self.src()}, {self.src()}")

    def mul(self):
        self.emit(f"mul {self.dest()}, {self.src()}, {self.src()}")

    def lui(self):
        self.emit(f"lui {self.dest()}, {self.r.choice(UIMM)}")

    def move(self):
        self.emit(f"move {self.dest()}, {self.src()}")

    def mem_offset(self, op: str, lo_word: int, hi_word: int) -> int:
        w = self.r.randint(lo_word, hi_word)
        size = {"w": 4, "h": 2, "b": 1}[op[1]]
        return w * 4 + self.r.randrange(0, 4, size)

    def load(self):
        op = self.r.choice(["lw", "lw", "lw", "lh", "lhu", "lb", "lbu"])
        off = self.mem_offset(op, 0, WIN_WORDS - 1)
        self.emit(f"{op} {self.dest()}, {off}($gp)")

    def store(self):
        op = self.r.choice(["sw", "sw", "sw", "sh", "sb"])
        off = self.mem_offset(op, PTR_SLOTS, WIN_WORDS - 1)
        self.emit(f"{op} {self.src()}, {off}($gp)")

    def ptr_computed(self):
        """addiu $fp,$gp,x ; 0-2 fillers ; load/store through $fp."""
        j = self.r.randint(PTR_SLOTS, 40)
        self.emit(f"addiu $fp, $gp, {4 * j}")
        for _ in range(self.r.choice([0, 0, 1, 2])):
            self.simple(no_mem_ptr=True)
        self.ptr_access(j)

    def ptr_loaded(self):
        """lw $fp, slot($gp) ; immediately use $fp as an address (load-use on the base)."""
        t = self.r.randrange(PTR_SLOTS)
        self.emit(f"lw $fp, {4 * t}($gp)")
        if self.r.random() < 0.3:
            self.simple(no_mem_ptr=True)
        self.ptr_access(self.ptr_targets[t])

    def ptr_access(self, j: int):
        op = self.r.choice(["lw", "lw", "sw", "sw", "lh", "lb", "lbu", "sb", "sh", "lhu"])
        m = self.r.randint(0, min(20, WIN_WORDS - 1 - j))
        size = {"w": 4, "h": 2, "b": 1}[op[1]]
        off = 4 * m + self.r.randrange(0, 4, size)
        if op[0] == "l":
            self.emit(f"{op} {self.dest()}, {off}($fp)")
        else:
            self.emit(f"{op} {self.src()}, {off}($fp)")

    def simple(self, no_mem_ptr: bool = False):
        weights = [(self.alu_rr, 26), (self.alu_imm, 20), (self.shift, 8), (self.mul, 3), (self.lui, 3),
                   (self.move, 2), (self.load, 13), (self.store, 9)]
        if not no_mem_ptr:
            weights += [(self.ptr_computed, 3), (self.ptr_loaded, 4)]
        fns, ws = zip(*weights)
        self.r.choices(fns, ws)[0]()

    # ---------------------------------------------------------------- control flow
    def branch_block(self):
        r = self.r
        lab = self.label()
        if r.random() < 0.45:
            op = r.choice(["beq", "bne"])
            self.emit(f"{op} {self.src()}, {self.src()}, {lab}")
        else:
            op = r.choice(["blez", "bgtz", "bltz", "bgez"])
            self.emit(f"{op} {self.src()}, {lab}")
        for _ in range(r.choice([0, 1, 1, 2, 3, 4])):       # the (possibly skipped) shadow
            if r.random() < 0.08:
                self.emit(f"j {lab}")                      # control flow in the shadow
            else:
                self.simple()
        self.place(lab)

    def jump_block(self):
        lab = self.label()
        self.emit(f"j {lab}")
        for _ in range(self.r.choice([0, 1, 2, 3])):
            self.simple()
        self.place(lab)

    def indirect_block(self):
        lab = self.label()
        k = self.r.random()
        if k < 0.6 and len(self.jt) < JT_SLOTS:
            slot = len(self.jt)
            self.jt.append(lab)
            self.emit(f"lw $t9, {JT_BASE + 4 * slot}($zero)")
            self.emit("jr $t9", 1)
        else:
            self.emit(f"la $t9, {lab}", 2)
            self.emit("jr $t9" if self.r.random() < 0.7 else "jalr $t9")
        for _ in range(self.r.choice([0, 1, 2])):
            self.simple()
        self.place(lab)

    def loop_block(self):
        r = self.r
        lab = self.label("LOOP")
        self.emit(f"li $s7, {r.randint(2, 5)}")
        self.place(lab)
        for _ in range(r.randint(2, 6)):
            self.simple()
        self.emit("addiu $s7, $s7, -1")
        self.emit(f"bgtz $s7, {lab}")

    def call_block(self):
        self.uses_funcs = True
        f = f"FUNC{self.r.randrange(self.nfuncs)}"
        if self.r.random() < 0.65:
            self.emit(f"jal {f}")
        else:
            self.emit(f"la $t9, {f}", 2)
            self.emit("jalr $t9")
        if self.r.random() < 0.5:
            self.simple()           # consume results right after return

    # ------------------------------------------------------------------- program
    def build(self) -> str:
        r = self.r
        fault = None
        if r.random() < 1 / 16:
            fault = r.choice(["illegal", "mis_lw", "mis_sw", "range_lw", "range_sb", "mis_jr"])
        hdr = ["# constrained-random program (tools/randgen.py)"]
        if fault:
            cause = {"illegal": "illegal", "mis_lw": "addr", "mis_sw": "addr",
                     "range_lw": "addr", "range_sb": "addr", "mis_jr": "addr"}[fault]
            hdr += [f"#! expect-cause={cause}", "#! no-selfcheck", f"# injected fault: {fault}"]
        else:
            hdr += ["#! no-selfcheck"]
        self.lines += hdr + [".text"]
        self.emit(f"li $gp, {WIN_BASE}")
        for reg in self.pool:
            self.emit(f"li {reg}, {self._signed(self.rand_word())}", 2)

        kinds = [(self.simple, 62), (self.branch_block, 11), (self.jump_block, 3), (self.indirect_block, 4),
                 (self.loop_block, 4), (self.call_block, 5)]
        fns, ws = zip(*kinds)
        while self.count < self.target:
            r.choices(fns, ws)[0]()

        if fault:
            self.simple()
            self.simple()
            self.inject(fault)
        self.lines.append(".endtest")

        for i in range(self.nfuncs):
            self.place(f"FUNC{i}")
            for _ in range(r.randint(2, 6)):
                self.simple(no_mem_ptr=(r.random() < 0.5))
            self.emit("jr $ra")

        self.lines.append(".data")
        self.lines.append(f".org {JT_BASE}")
        for i in range(JT_SLOTS):
            self.lines.append(f".word {self.jt[i] if i < len(self.jt) else 0}")
        self.lines.append(f".org {WIN_BASE}")
        for t in range(PTR_SLOTS):
            self.lines.append(f".word {WIN_BASE + 4 * self.ptr_targets[t]}")
        for w in range(PTR_SLOTS, WIN_WORDS):
            self.lines.append(f".word {self.words[w]}")
        return "\n".join(self.lines) + "\n"

    @staticmethod
    def _signed(v: int) -> int:
        return v - (1 << 32) if v & 0x80000000 else v

    def inject(self, kind: str):
        d = self.r.choice(self.pool)
        if kind == "illegal":
            self.emit(f".inst {self.r.choice(['0xFFFFFFFF', '0xFC000000', '0x7C000000', '0x0000002C'])}")
        elif kind == "mis_lw":
            self.emit(f"lw {d}, {4 * self.r.randint(0, 20) + self.r.choice([1, 2, 3])}($gp)")
        elif kind == "mis_sw":
            self.emit(f"{self.r.choice(['sw', 'sh'])} {self.src()}, {4 * self.r.randint(8, 20) + self.r.choice([1, 3])}($gp)")
        elif kind == "range_lw":
            self.emit("lui $t9, 0x1")
            self.emit(f"lw {d}, 0($t9)")
        elif kind == "range_sb":
            self.emit("addiu $t9, $zero, -4")
            self.emit(f"sb {self.src()}, 0($t9)")
        elif kind == "mis_jr":
            self.emit("addiu $t9, $zero, 10")
            self.emit("jr $t9")
        self.emit(f"li {d}, 1")        # younger instruction that must not commit
        self.emit(f"sw {d}, {4 * 9}($gp)")


def generate(seed: int, length: int = 400) -> str:
    return Gen(seed, length).build()


if __name__ == "__main__":
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    length = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    sys.stdout.write(generate(seed, length))
