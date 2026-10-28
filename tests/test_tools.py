#!/usr/bin/env python3
"""Unit tests for the Python tool-chain (assembler / disassembler / ISS / perf model).

The assembler is checked against encodings taken from the MIPS32 architecture manual
(externally known-good words), so a shared mis-reading of the ISA between assembler
and ISS cannot hide behind self-consistency.
"""
import random
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import asm  # noqa: E402
import isa  # noqa: E402
import iss  # noqa: E402
import perfmodel  # noqa: E402


def one(line):
    return asm.assemble(".text\n" + line + "\n").imem[0]


class Encodings(unittest.TestCase):
    # (assembly, word) -- reference encodings from the MIPS32 manual / common toolchains
    REF = [
        ("addu $t2, $t0, $t1", 0x01095021), ("addiu $t0, $zero, 5", 0x24080005),
        ("lw $t0, 4($sp)", 0x8FA80004), ("sw $ra, 0($sp)", 0xAFBF0000),
        ("jr $ra", 0x03E00008), ("lui $t0, 0x1234", 0x3C081234),
        ("slt $t0, $t1, $t2", 0x012A402A), ("sll $t0, $t1, 4", 0x00094100),
        ("mul $t0, $t1, $t2", 0x712A4002), ("break", 0x0000000D),
        ("srav $t0, $t1, $t2", 0x01494007), ("andi $t0, $t1, 0xFF", 0x312800FF),
        ("nor $t0, $t1, $t2", 0x012A4027), ("sub $v0, $a0, $a1", 0x00851022),
        ("lb $t0, -1($a0)", 0x8088FFFF), ("sh $t0, 2($a0)", 0xA4880002),
        ("sltiu $t0, $t1, -1", 0x2D28FFFF), ("xori $t0, $t1, 0x8000", 0x39288000),
        ("jalr $ra, $t9", 0x0320F809), ("nop", 0x00000000),
    ]

    def test_reference_words(self):
        for src, word in self.REF:
            self.assertEqual(one(src), word, src)

    def test_branch_and_jump_encodings(self):
        p = asm.assemble(".text\nL: beq $zero, $zero, L\n bne $t0, $t1, L\n j L\n jal L\n bgez $t0, L\n bltz $t0, L\n")
        self.assertEqual(p.imem[0], 0x1000FFFF)     # beq $0,$0,-1
        self.assertEqual(p.imem[1], 0x1509FFFE)     # bne $t0,$t1,-2
        self.assertEqual(p.imem[2], 0x08000000)     # j 0
        self.assertEqual(p.imem[3], 0x0C000000)     # jal 0
        self.assertEqual(p.imem[4], 0x0501FFFB)     # bgez rt=1
        self.assertEqual(p.imem[5], 0x0500FFFA)     # bltz rt=0

    def test_pseudo_expansion(self):
        self.assertEqual(asm.assemble(".text\nli $t0, 0x12345678\n").imem, [0x3C081234, 0x35085678])
        self.assertEqual(asm.assemble(".text\nli $t0, -1\n").imem, [0x2408FFFF])
        self.assertEqual(asm.assemble(".text\nli $t0, 0xFFFF\n").imem, [0x3408FFFF])
        self.assertEqual(asm.assemble(".text\nmove $t0, $t1\n").imem, [0x01204021])

    def test_range_errors(self):
        for bad in ("addiu $t0,$t0,40000", "andi $t0,$t0,-1", "sll $t0,$t0,32", "lw $t0, 70000($zero)", "foo $t0"):
            with self.assertRaises(asm.AsmError, msg=bad):
                asm.assemble(".text\n" + bad + "\n")

    def test_disasm_roundtrip_all_ops(self):
        rnd = random.Random(7)
        n = 0
        for _ in range(4000):
            w = rnd.getrandbits(32)
            if isa.lookup(w) is None or w == 0:
                continue
            f = isa.fields(w)
            name = isa.lookup(w).name
            if name in ("j", "jal", "beq", "bne", "blez", "bgtz", "bltz", "bgez"):
                continue                                   # absolute targets: covered above
            text = isa.disasm(w, 0)
            re = asm.assemble(".text\n" + text + "\n").imem[0]
            # reserved fields are not preserved by the disassembler -> compare through lookup/fields
            self.assertEqual(isa.lookup(re).name, name, text)
            n += 1
        self.assertGreater(n, 100)


class Simulator(unittest.TestCase):
    def run_prog(self, src, **kw):
        p = asm.assemble(src)
        return iss.run(p.imem, p.dmem_words(), **kw), p

    def test_arith_semantics(self):
        r, _ = self.run_prog(".text\n li $t0,-1\n li $t1,1\n sltu $t2,$t0,$t1\n slt $t3,$t0,$t1\n sra $t4,$t0,4\n"
                             " srl $t5,$t0,4\n mul $t6,$t0,$t0\n sltiu $t7,$t1,-1\n break\n")
        R = r.regs
        self.assertEqual((R[10], R[11], R[12], R[13], R[14], R[15]), (0, 1, 0xFFFFFFFF, 0x0FFFFFFF, 1, 1))

    def test_branch_no_delay_slot(self):
        r, _ = self.run_prog(".text\n li $t0,1\n bne $t0,$zero,L\n li $t1,99\nL: break\n")
        self.assertEqual(r.regs[9], 0)                     # instruction after taken branch NOT executed

    def test_link_is_pc_plus_4(self):
        r, _ = self.run_prog(".text\n nop\n jal f\n break\nf: jr $ra\n")
        self.assertEqual(r.regs[31], 8)

    def test_subword_memory(self):
        r, _ = self.run_prog(".text\n li $t0,0x80\n sb $t0,1($zero)\n lb $t1,1($zero)\n lbu $t2,1($zero)\n lw $t3,0($zero)\n break\n")
        self.assertEqual((r.regs[9], r.regs[10], r.regs[11]), (0xFFFFFF80, 0x80, 0x8000))

    def test_halt_causes(self):
        r, _ = self.run_prog(".text\n lw $t0, 2($zero)\n break\n")
        self.assertEqual((r.cause, r.halt_pc, r.halt_addr), (isa.EXC_ADDR, 0, 2))
        r, _ = self.run_prog(".text\n nop\n .inst 0xFFFFFFFF\n")
        self.assertEqual((r.cause, r.halt_pc), (isa.EXC_ILLEGAL, 4))
        r, _ = self.run_prog(".text\n li $t0,6\n jr $t0\n")
        self.assertEqual(r.cause, isa.EXC_ADDR)
        self.assertEqual(r.instret, 1)                     # the jr itself does not retire


class PerfModel(unittest.TestCase):
    def predict(self, src):
        p = asm.assemble(src)
        r = iss.run(p.imem, p.dmem_words())
        return perfmodel.predict(r, p.imem), perfmodel.timeline(r, p.imem), r

    def test_straight_line(self):
        a, t, _ = self.predict(".text\n nop\n nop\n nop\n break\n")
        self.assertEqual((a.cycles, t.cycles), (8, 8))      # 4 instructions + 4 fill

    def test_load_use_and_branch(self):
        a, t, _ = self.predict(".text\n lw $t0,0($zero)\n addu $t1,$t0,$t0\n beq $zero,$zero,L\n nop\nL: break\n")
        self.assertEqual(a.stalls_loaduse, 1)
        self.assertEqual(a.redirects_ex, 1)
        self.assertEqual(a.cycles, 4 + 4 + 1 + 2)
        self.assertEqual(t.cycles, a.cycles)

    def test_store_data_not_a_stall_with_mem_mem(self):
        src = ".text\n lw $t0,0($zero)\n sw $t0,4($zero)\n break\n"
        p = asm.assemble(src)
        r = iss.run(p.imem, p.dmem_words())
        self.assertEqual(perfmodel.predict(r, p.imem, True).stalls_loaduse, 0)
        self.assertEqual(perfmodel.predict(r, p.imem, False).stalls_loaduse, 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
