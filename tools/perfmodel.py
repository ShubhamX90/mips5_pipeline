"""Analytical cycle-accurate performance model of the 5-stage pipeline.

Given only the *dynamic instruction stream* produced by the ISS it predicts the
exact cycle count and the stall / flush decomposition of the RTL.  The
regression requires the RTL's hardware counters to match this model for every
program, which cross-validates the hazard unit's timing (not just its
functional results).

Pipeline timing rules (see docs/HAZARDS.md):
  fill         4 cycles  (first instruction reaches WB in cycle 5)
  load-use     +1 per instruction whose very next dynamic successor consumes
               the loaded register (rt of a store excluded when MEM->MEM
               forwarding is on)
  taken branch / jr / jalr   +2   (EX-stage resolution, two slots squashed)
  j / jal                    +1   (ID-stage resolution, one slot squashed)
  halting fault (illegal / address error) occupies a WB slot without retiring: +1
Single-cycle core: cycles == retired instructions (+1 for a non-retiring fault).
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isa  # noqa: E402

FILL = 4


@dataclass
class Prediction:
    cycles: int
    instret: int
    stalls_loaduse: int
    redirects_ex: int
    redirects_id: int
    squashed: int
    branches: int
    branches_taken: int

    def as_dict(self):
        return self.__dict__.copy()


def predict(res, imem_words, mem_mem_fwd: bool = True) -> Prediction:
    """`res` is an iss.Result; `imem_words` the program image."""
    stream = [(r.instr, r.taken) for r in res.retired]
    nonretiring_fault = res.cause in (isa.EXC_ILLEGAL, isa.EXC_ADDR)
    if nonretiring_fault:
        idx = res.halt_pc >> 2
        word = imem_words[idx] if 0 <= idx < len(imem_words) else isa.ILLEGAL_FETCH
        stream.append((word, False))          # participates in hazards, never redirects

    stalls = rex = rid = br = brt = 0
    prev = None
    for instr, taken in stream:
        u = isa.usage(instr)
        if u is not None:
            if prev is not None and prev.is_load and prev.dest != 0:
                rt_needed = u.uses_rt and not (mem_mem_fwd and u.is_store)
                f = isa.fields(instr)
                if (u.uses_rs and f["rs"] == prev.dest) or (rt_needed and f["rt"] == prev.dest):
                    stalls += 1
            if u.is_cond_branch:
                br += 1
                if taken:
                    brt += 1
                    rex += 1
            elif u.is_jr and taken:
                rex += 1
            elif u.is_direct_jump:
                rid += 1
        prev = u
    n = res.instret
    squashed = 2 * rex + rid
    cycles = n + (1 if nonretiring_fault else 0) + FILL + stalls + squashed
    return Prediction(cycles, n, stalls, rex, rid, squashed, br, brt)


def predict_single(res) -> int:
    return res.instret + (1 if res.cause in (isa.EXC_ILLEGAL, isa.EXC_ADDR) else 0)
