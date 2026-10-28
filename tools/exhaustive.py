#!/usr/bin/env python3
"""Bounded-exhaustive hazard sequences.

Every ordered sequence of K templates drawn from a 14-entry alphabet that mixes
dependent ALU ops, loads and stores through the same two registers, taken and
not-taken branches with a poisoned shadow, j / jal / jr, and a multiply is
executed -- under two operand initialisations (equal / unequal, so each branch
goes both ways).  With K = 4 that is 14^4 x 2 = 76,832 blocks (~800k retired
instructions); K = 3 is 5,488 blocks.

Blocks are packed ~250 per program (re-initialising the working registers
between blocks) and run through the full regression flow: lock-step against the
ISS on all three RTL variants, assertions, cycle-exact perf model.  Values are
kept small and aligned so no block ever faults; every dependent adjacent
interaction up to distance K-1 is therefore exercised in every combination.

Usage: exhaustive.py [--k 4] [--per-program 250]
"""
from __future__ import annotations

import argparse
import itertools
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import regress  # noqa: E402

# Each template: list of asm lines; "{L}" is replaced by a unique label.
TEMPLATES = [
    ["addiu $t0, $t0, 4"],
    ["addiu $t1, $t0, 8"],
    ["addu  $t0, $t0, $t1"],
    ["xor   $t1, $t1, $t0"],
    ["lw    $t0, 0($t1)"],
    ["lw    $t1, 0($t0)"],
    ["sw    $t0, 0($t1)"],
    ["sw    $t1, 4($t0)"],
    ["beq   $t0, $t1, {L}", "addiu $s0, $s0, 1", "{L}:"],
    ["bne   $t0, $t1, {L}", "addiu $s1, $s1, 1", "{L}:"],
    ["j     {L}", "addiu $s0, $s0, 2", "{L}:"],
    ["jal   {L}", "addiu $s1, $s1, 2", "{L}:"],
    ["mul   $t0, $t0, $t1", "andi  $t0, $t0, 0xFC"],
    ["la    $t2, {L}", "jr    $t2", "addiu $s0, $s0, 4", "{L}:"],
]
INITS = [(8, 8), (8, 12)]


def build_programs(k: int, per_program: int):
    progs, cur, n_blocks, lab = [], [], 0, 0
    for seq in itertools.product(range(len(TEMPLATES)), repeat=k):
        for (a, b) in INITS:
            cur.append(f"    li $t0, {a}\n    li $t1, {b}")
            for t in seq:
                for line in TEMPLATES[t]:
                    if line.endswith(":"):
                        cur.append(line.replace("{L}", f"L{lab}"))
                    else:
                        cur.append("    " + line.replace("{L}", f"L{lab}"))
                lab += 1
            n_blocks += 1
            if n_blocks % per_program == 0:
                progs.append(cur)
                cur, lab = [], 0
    if cur:
        progs.append(cur)
    return progs, n_blocks


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--k", type=int, default=4)
    ap.add_argument("--per-program", type=int, default=250)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    progs, n_blocks = build_programs(args.k, args.per_program)
    d = ROOT / "build" / "exhaustive_src"
    d.mkdir(parents=True, exist_ok=True)
    cases = []
    for i, body in enumerate(progs):
        p = d / f"exh_k{args.k}_{i:04d}.s"
        hdr = ["#! no-selfcheck", f"# bounded-exhaustive block {i}", ".text", "    li $s0, 0", "    li $s1, 0"]
        p.write_text("\n".join(hdr + body + [".endtest"]) + "\n")
        cases.append((p.stem, p))
    print(f"exhaustive K={args.k}: {n_blocks} blocks in {len(cases)} programs")
    results = regress.run_many(cases, regress.BUILD / "exhaustive", args.jobs, ("pipe", "nomm", "single"))
    bad = [r for r in results if not r["ok"]]
    instr = sum(r["variants"]["pipe"]["perf"]["instret"] for r in results if r["variants"].get("pipe"))
    checks = sum(r["variants"]["pipe"].get("assert_checks", 0) for r in results if r["variants"].get("pipe"))
    print(f"{len(results)-len(bad)}/{len(results)} programs passed; {instr:,} instructions retired on each RTL variant; "
          f"{checks:,} assertion evaluations")
    for r in bad[:10]:
        print(f"FAIL {r['name']}")
        for e in r["errors"]:
            print(f"   ! {e}")
    print("EXHAUSTIVE " + ("PASSED" if not bad else "FAILED"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
