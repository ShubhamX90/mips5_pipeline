#!/usr/bin/env python3
"""Pipeline diagram generator: run a program on the pipelined RTL and draw which
instruction occupied which stage in every cycle.

    F D X M W   normal progress           d  instruction held in ID (load-use stall)
    f           held in IF behind a stall x  squashed (wrong path / flushed)
    .           (nothing)

Usage: pipeview.py prog.s [--from CYCLE] [--cycles N] [--variant pipe|nomm]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import asm  # noqa: E402
import isa  # noqa: E402


def collect(prog_path: Path, variant: str):
    prog = asm.assemble_file(prog_path)
    with tempfile.TemporaryDirectory() as td:
        pre = Path(td) / "p"
        asm.write_outputs(prog, pre)
        sim = ROOT / "build" / ("sim_pipe.vvp" if variant == "pipe" else "sim_pipe_nomm.vvp")
        subprocess.run(["vvp", str(sim), f"+IMEM={pre}.imem.hex", f"+DMEM={pre}.dmem.hex",
                        f"+PIPETRACE={pre}.pipe"], capture_output=True, check=True)
        rows = [list(map(int, ln.split()[:1])) + [int(x, 16) if i in (0, 2, 4, 6, 8) else int(x)
                                                  for i, x in enumerate(ln.split()[1:])]
                for ln in (pre.with_suffix(".pipe")).read_text().splitlines()]
    return prog, rows


def build_instances(rows):
    """Follow instruction instances through the pipeline using the stall/flush controls."""
    inst = []                        # [pc, {cycle: letter}]
    cur = {"IF": None, "ID": None, "EX": None, "MEM": None, "WB": None}
    for r in rows:
        cyc, ifpc, idv, idpc, exv, expc, mmv, mmpc, wbv, wbpc, stall, fl_ifid, fl_idex = r
        # cur["IF"] is the instruction being fetched this cycle
        if cur["IF"] is None:
            inst.append([ifpc, {}])
            cur["IF"] = len(inst) - 1
        cells = {"IF": ("f" if (cur["IF"] is not None and stall and False) else "F"),
                 "ID": "d" if stall else "D", "EX": "X", "MEM": "M", "WB": "W"}
        for st in ("IF", "ID", "EX", "MEM", "WB"):
            i = cur[st]
            if i is None:
                continue
            ch = cells[st]
            if st == "IF" and stall:
                ch = "f"
            inst[i][1][cyc] = ch
        nxt = {"IF": None, "ID": None, "EX": None, "MEM": cur["EX"], "WB": cur["MEM"]}
        if stall:
            nxt["ID"], nxt["IF"] = cur["ID"], cur["IF"]
            nxt["EX"] = None
        else:
            nxt["EX"] = None if fl_idex else cur["ID"]
            nxt["ID"] = None if fl_ifid else cur["IF"]
            if fl_idex and cur["ID"] is not None:
                inst[cur["ID"]][1][cyc + 1] = "x"
            if fl_ifid and cur["IF"] is not None:
                inst[cur["IF"]][1][cyc + 1] = "x"
        cur = nxt
    return inst


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("program")
    ap.add_argument("--from", dest="start", type=int, default=1)
    ap.add_argument("--cycles", type=int, default=40)
    ap.add_argument("--variant", default="pipe")
    a = ap.parse_args()
    prog, rows = collect(Path(a.program), a.variant)
    inst = build_instances(rows)
    lo, hi = a.start, a.start + a.cycles - 1
    imem = prog.imem
    print(f"{'pc':>6}  {'instruction':<28}" + "".join(f"{c % 100:>2}" if c % 5 == 0 else "  " for c in range(lo, hi + 1)))
    for pc, cells in inst:
        if not any(lo <= c <= hi for c in cells):
            continue
        word = imem[pc >> 2] if (pc >> 2) < len(imem) else isa.ILLEGAL_FETCH
        line = "".join(f" {cells.get(c, '.')}" for c in range(lo, hi + 1))
        print(f"{pc:06x}  {isa.disasm(word, pc):<28}{line}")


if __name__ == "__main__":
    main()
